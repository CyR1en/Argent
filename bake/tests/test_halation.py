"""The halation geometry of a 0.10 mm base, and every stock's halation against it."""

import numpy as np
import pytest

from argent_bake.halation import (BASE_UM, HEAVY_TAILED, MIXTURE, RADIUS_UM, UNDERCOAT_RANGE, cdf_on, mixture_cdf,
                                  quantiles, returned, strength_bounds)
from tests.conftest import STOCK_NAMES

GRID = np.linspace(0.0, 32 * RADIUS_UM, 8000)


def _geometry(undercoat: float) -> tuple:
    radius, energy = returned(undercoat)
    return quantiles(GRID, cdf_on(GRID, radius, energy)), float(energy.sum())


def test_total_internal_reflection_starts_where_the_base_puts_it():
    radius, energy = returned(0.0)
    # Past the critical angle the back surface reflects everything, from 2 t / sqrt(n^2 - 1) out.
    ring = 2 * BASE_UM / np.sqrt(1.65 ** 2 - 1)
    assert ring == pytest.approx(152, abs=1)
    assert energy[radius >= ring].sum() / energy.sum() > 0.9
    # With no undercoat a Lambertian source gets 1 - 1/n_g^2 back by total reflection, plus Fresnel.
    assert energy.sum() == pytest.approx(1 - 1 / 1.54 ** 2 + 0.05, abs=0.01)


def test_a_denser_undercoat_returns_less_and_closer_in():
    (q_thin, e_thin), (q_dense, e_dense) = _geometry(UNDERCOAT_RANGE[0]), _geometry(UNDERCOAT_RANGE[1])
    assert e_dense < e_thin / 10
    assert q_dense[1] < q_thin[1] and q_dense[2] < q_thin[2]
    assert q_thin[2] < 350  # nine tenths of the halo inside 350 um even at the thinnest undercoat


def test_the_shipped_kernel_follows_the_geometry_and_the_heavy_tail_did_not():
    medians = [_geometry(d)[0][1] for d in UNDERCOAT_RANGE]
    widest = _geometry(UNDERCOAT_RANGE[0])[0][2]
    kernel = quantiles(GRID, mixture_cdf(GRID, MIXTURE))
    assert min(medians) * 0.9 <= kernel[1] <= max(medians) * 1.1
    assert kernel[2] <= 1.5 * widest
    assert MIXTURE.sum() == pytest.approx(1.0)
    heavy = quantiles(GRID, mixture_cdf(GRID, HEAVY_TAILED))
    assert heavy[2] > 4 * widest


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_every_stocks_halation_sits_inside_what_its_base_allows(stocks, name):
    halation = stocks[name].halation
    low, high = strength_bounds()
    assert low <= halation["strength"] <= high
    assert halation["radiusMicrometres"] == RADIUS_UM
    assert 0 <= halation["greenShare"] <= 1
