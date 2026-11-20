#!/usr/bin/env python3
"""Print the halation geometry of a 0.10 mm base: how much light it returns and how far it spreads.

The physics is `argent_bake.halation`. This prints the ring's start, the share of the light
returned and its radial quantiles over a range of undercoat densities, beside the render's kernel
as it was until 2026-10-07; fits the kernel's six Gaussian weights (sigmas 0.5a to 16a, a = the
profiles' radius) to the geometric profile by non-negative least squares on the radial energy; and
prints the strengths the geometry allows over Kodak's undercoat range. `docs/research/film.md`
section 4.4 has the numbers. Nothing here is fitted to a picture.

    cd bake && PYTHONPATH=. ../.venv/bin/python tools/halation_geometry.py
"""

import numpy as np

from argent_bake.halation import (BASE_UM, HEAVY_TAILED, MIXTURE, RADIUS_UM, REFERENCE_UNDERCOAT, SCALES,
                                  UNDERCOAT_RANGE, cdf_on, mixture_cdf, quantiles, returned, strength_bounds)


def fit_weights(grid: np.ndarray, target: np.ndarray, iterations: int = 50_000) -> np.ndarray:
    """Non-negative weights summing to one whose mixture CDF is nearest `target` (projected gradient)."""
    columns = 1 - np.exp(-grid[:, None] ** 2 / (2 * (SCALES * RADIUS_UM) ** 2))
    system = np.vstack([columns, 50.0 * np.ones(SCALES.size)])
    goal = np.append(target, 50.0)
    step = 1.0 / np.linalg.norm(system, 2) ** 2
    weights = np.full(SCALES.size, 1.0 / SCALES.size)
    for _ in range(iterations):
        weights = np.maximum(0.0, weights - step * system.T @ (system @ weights - goal))
    return weights / weights.sum()


def main() -> None:
    grid = np.linspace(0.0, 32 * RADIUS_UM, 8000)
    for index in (1.50, 1.65):
        print(f"base index {index}: total internal reflection from r = "
              f"{2 * BASE_UM / np.sqrt(index ** 2 - 1):.0f} um on a {BASE_UM:.0f} um base")
    shipped = quantiles(grid, mixture_cdf(grid, HEAVY_TAILED))
    print(f"the kernel shipped until 2026-10-07 (a = {RADIUS_UM:.0f} um): 10, 50, 90 percent of the halo inside "
          f"{shipped[0]:.0f}, {shipped[1]:.0f}, {shipped[2]:.0f} um")
    print("undercoat D  base dye  returned  inside 10/50/90 percent (um)  shipped kernel's largest CDF error")
    for base_dye in (0.0, 0.05):
        for undercoat in (0.0, 0.1, 0.13, 0.2, 0.3, 0.4, 0.49, 0.75, 1.0):
            radius, energy = returned(undercoat, base_dye)
            cdf = cdf_on(grid, radius, energy)
            q = quantiles(grid, cdf)
            error = np.abs(mixture_cdf(grid, HEAVY_TAILED) - cdf).max()
            print(f"{undercoat:11.2f} {base_dye:9.2f} {energy.sum():9.4f}   {q[0]:5.0f} {q[1]:5.0f} {q[2]:5.0f}"
                  f"                  {error:.2f}")
    print("weights fitted to the geometry (sigmas 0.5a, 1a, 2a, 4a, 8a, 16a):")
    for undercoat in (0.13, 0.3, REFERENCE_UNDERCOAT, 0.49):
        radius, energy = returned(undercoat)
        cdf = cdf_on(grid, radius, energy)
        weights = fit_weights(grid, cdf)
        q = quantiles(grid, mixture_cdf(grid, weights))
        print(f"  undercoat {undercoat:.2f}: " + ", ".join(f"{w:.3f}" for w in weights)
              + f"; inside {q[0]:.0f}, {q[1]:.0f}, {q[2]:.0f} um; largest CDF error "
              f"{np.abs(mixture_cdf(grid, weights) - cdf).max():.2f}")
    low, high = strength_bounds()
    print(f"strengths the geometry allows for undercoats of {UNDERCOAT_RANGE[0]} to {UNDERCOAT_RANGE[1]}: "
          f"{low:.4f} to {high:.4f}")
    q = quantiles(grid, mixture_cdf(grid, MIXTURE))
    print("the shipped weights since 2026-10-07, " + ", ".join(f"{w:.2f}" for w in MIXTURE)
          + f": inside {q[0]:.0f}, {q[1]:.0f}, {q[2]:.0f} um")


if __name__ == "__main__":
    main()
