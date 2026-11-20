import json

import numpy as np
import pytest

from argent_bake import synthetic
from argent_bake.densitometry import status_jacobian, status_weights
from argent_bake.grain import (PIXEL_RATIO, amount_variances, density_response, net_density, print_noise,
                               stock_sigma_density)
from argent_bake.negative import MID_GRAY, dye_amounts
from argent_bake.printing import GRAY_TARGET, Printer, calibrate
from argent_bake.profile import ProfileError, load_profile

from conftest import STOCK_NAMES, STOCKS


def _setup(profile, paper):
    printer = Printer(paper, profile.dyes, profile.base)
    return printer, calibrate(printer, dye_amounts(profile, np.full(3, MID_GRAY)), GRAY_TARGET)


def test_the_synthetic_print_reproduces_the_research_numbers():
    # The M3 grain research put sigma_D 0.01 per layer through the synthetic print and found
    # sigma_Y / Y of 3.1, 2.85, 2.15, 1.2, 0.56 and 0.24 percent at -2 to +4 stops, and output
    # correlations R-G +0.8, G-B +0.8, R-B +0.55. Its synthetic stock sat about half a stop
    # differently on its curves (read half a stop higher, today's gains match within 10
    # percent), so the gains hold to 30 percent, 50 at +4, and the correlations to 0.05.
    profile = synthetic.profile()
    printer, filtration = _setup(profile, synthetic.paper())
    for stops, expected in ((-2, 3.1), (0, 2.85), (1, 2.15), (2, 1.2), (3, 0.56), (4, 0.24)):
        got = print_noise(profile, printer, filtration, stops, [0.01] * 3).relative_luminance_sigma * 100
        assert got == pytest.approx(expected, rel=0.5 if stops == 4 else 0.3), f"{stops:+d} stops"
    corr = print_noise(profile, printer, filtration, 0, [0.01] * 3).correlation
    assert corr[0, 1] == pytest.approx(0.8, abs=0.05)
    assert corr[1, 2] == pytest.approx(0.8, abs=0.05)
    assert corr[0, 2] == pytest.approx(0.55, abs=0.05)


def test_through_endura_grain_shows_in_the_mid_tones_and_vanishes_at_both_ends(stocks, endura):
    for name in STOCK_NAMES:
        profile = stocks[name]
        printer, filtration = _setup(profile, endura)
        gains = {s: print_noise(profile, printer, filtration, s, [0.01] * 3).relative_luminance_sigma
                 for s in (-6, -4, -2, -1, 0, 1, 2, 4, 5)}
        peak = max(gains, key=gains.get)
        assert peak in (-1, 0), f"{name}: peak at {peak:+d} stops"
        assert 0.055 < gains[peak] < 0.08, name
        assert gains[4] < gains[peak] / 100, name
        assert gains[5] < gains[peak] / 150, name
        assert gains[-6] < gains[-2] / 5, name
        corr = print_noise(profile, printer, filtration, 0, [0.01] * 3).correlation
        assert np.allclose(corr, corr.T) and np.allclose(np.diag(corr), 1.0)
        # Real paper dyes leave the channels less correlated than the synthetic print did.
        assert 0.6 < corr[0, 1] < 0.75 and 0.45 < corr[1, 2] < 0.6 and 0.2 < corr[0, 2] < 0.32, name


def test_amount_variances_reproduce_the_channel_variances(stocks, endura):
    profile = stocks["portra400"]
    amounts = dye_amounts(profile, np.full(3, MID_GRAY))
    sigma = np.array([0.01, 0.012, 0.02])
    variances = amount_variances(profile, amounts, sigma)
    j = status_jacobian(profile.base + profile.dyes @ amounts, status_weights("M"), profile.dyes)
    np.testing.assert_allclose((j * j) @ variances, sigma ** 2, rtol=1e-9)
    printer, filtration = _setup(profile, endura)
    assert print_noise(profile, printer, filtration, 0, [0, 0, 0]).relative_luminance_sigma == 0.0


def test_the_full_chain_uses_the_profiles_grain_and_the_pixel_pitch(stocks):
    profile = stocks["portra400"]
    np.testing.assert_allclose(profile.grain_rms48, [0.0050, 0.0055, 0.0132])
    # Mid-gray sits on the straight part: net densities 0.61, 0.66, 0.83 on Portra 400.
    np.testing.assert_allclose(net_density(profile, 0), [0.61, 0.66, 0.83], atol=0.01)
    full = stock_sigma_density(profile, profile.grain_rms48, 0, 7008)
    export = stock_sigma_density(profile, profile.grain_rms48, 0, 2048)
    np.testing.assert_allclose(full / export, PIXEL_RATIO[7008] / PIXEL_RATIO[2048])
    np.testing.assert_allclose(full, profile.grain_rms48 * 4.02 * density_response(net_density(profile, 0)))
    with pytest.raises(ValueError):
        stock_sigma_density(profile, profile.grain_rms48, 0, 5000)
    # The response peaks in the toe, as the research found.
    assert np.all(density_response(np.full(3, 0.2)) > density_response(np.full(3, 1.0)))


def test_the_profile_loader_reads_and_checks_the_grain_field(tmp_path):
    data = json.loads((STOCKS / "portra400.json").read_text())
    data["grain"]["rmsGranularity48um"] = [0.005, -0.001, 0.01]
    with pytest.raises(ProfileError):
        load_profile(data)
    del data["grain"]
    assert load_profile(data).grain_rms48 is None


def test_the_manifest_table_peaks_in_the_toe_and_follows_the_layers_own_amounts(stocks):
    from argent_bake.grain import TABLE_STOPS, grain_table
    profile = stocks["portra400"]
    table = grain_table(profile, density_range=2.5)
    amounts, sigmas = np.array(table["amounts"]), np.array(table["sigma48"])
    assert amounts.shape == sigmas.shape == (len(TABLE_STOPS), 3)
    # Monotonic per layer, so the app can look a pixel's sigma up by its own dye amount.
    assert np.all(np.diff(amounts, axis=0) >= 0)
    # Grain peaks a few stops under mid-gray, in the toe, as the density response does (F7).
    peak = TABLE_STOPS[np.argmax(sigmas[:, 1])]
    assert -4 <= peak <= -1
    mid = list(TABLE_STOPS).index(0.0)
    assert np.all(sigmas.max(axis=0) > sigmas[mid])
    # At mid-gray the green layer's sigma is the profile's in dye amounts: the order of
    # magnitude of 0.0055 D, divided by the density range.
    assert 0.0005 < sigmas[mid, 1] < 0.005


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_grain_follows_the_print_grain_index_ratio_to_portra_400(stocks, name):
    # Kodak's sheets print the Print Grain Index; the ratio of two stocks' granularities is
    # 10^(dPGI / 100.8) over the magnifications both print (docs/M3-research.md section 3).
    pgi = json.loads((STOCKS / f"{name}.json").read_text())["grain"]["printGrainIndex"]
    anchor = json.loads((STOCKS / "portra400.json").read_text())["grain"]["printGrainIndex"]
    deltas = [a - b for a, b in zip(pgi, anchor) if a is not None and b is not None]
    expected = 10 ** (np.mean(deltas) / 100.8)
    ratio = stocks[name].grain_rms48 / stocks["portra400"].grain_rms48
    np.testing.assert_allclose(ratio, expected, rtol=0.02)
