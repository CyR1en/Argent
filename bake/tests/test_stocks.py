"""The six datasheet stocks against what their sheets print, and the Portra 400 regression pin."""

import dataclasses
import json
import math

import numpy as np
import pytest

from argent_bake.checker import COLOURED, NEUTRAL_5, delta_e_2000, render, scene
from argent_bake.negative import (CYAN_TO_GREEN_LIMIT, GRAY_CARD_MARGIN, MAGENTA_TO_BLUE_LIMIT, MID_GRAY,
                                  UNMIX_RMS_LIMIT, WHITE_STEP_MARGIN, check_gates, density_range, dye_amounts,
                                  gray_card_red_density, gray_card_window_ok, inversion_residuals, iso5800_speed,
                                  gamma_ratios, largest_amount_fall, largest_curve_fall, mid_gray_log_exposure,
                                  exposure_matrix, log_exposure, lut_layer_exposure_peak, smooth_basis_matrix,
                                  white_step_red_density, white_step_window_ok)
from argent_bake.profile import TOP_SLOPE_POINTS
from argent_bake.printing import GRAY_TARGET, Printer, calibrate, exposure_per_unit
from tests.conftest import NEW_STOCK_NAMES, STOCK_NAMES, STOCKS

# Measured here on the reviewed extraction at 11.49 / S; the Phase 1 figures are the same to the last digit.
# "white" is the lightest step of a KODAK Paper Gray Scale (density 0.1), measured 2026-10-07.
EXPECTED = {
    "portra400": {"red": 0.835, "white": 1.184, "speed": 398, "box": 400},
    "portra160": {"red": 0.800, "white": 1.141, "speed": 145, "box": 160},
    "portra800": {"red": 0.855, "white": 1.192, "speed": 714, "box": 800},
    "ektar100": {"red": 0.868, "white": 1.232, "speed": 99, "box": 100},
    "gold200": {"red": 0.865, "white": 1.218, "speed": 207, "box": 200},
    "ultramax400": {"red": 0.903, "white": 1.239, "speed": 495, "box": 400},
}

# The name the app shows for each stock, the film's own without its maker, and the film it models.
NAMES = {
    "portra400": ("Portra 400", "Kodak Portra 400"),
    "portra160": ("Portra 160", "Kodak Portra 160"),
    "portra800": ("Portra 800", "Kodak Portra 800"),
    "gold200": ("Gold 200", "Kodak Gold 200"),
    "ultramax400": ("UltraMax 400", "Kodak UltraMax 400"),
    "ektar100": ("Ektar 100", "Kodak Ektar 100"),
}
@pytest.mark.parametrize("name", STOCK_NAMES)
def test_each_stock_is_named_for_the_film_it_models(stocks, name):
    profile = stocks[name]
    assert (profile.display_name, profile.modelled_film) == NAMES[name]
    # The film's name and the box speed.
    assert profile.display_name.endswith(f" {profile.box_speed:.0f}")
    assert profile.modelled_film.endswith(profile.display_name)


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_mid_gray_sits_inside_the_sheets_gray_card_window(stocks, name):
    profile = stocks[name]
    red = gray_card_red_density(profile)
    assert red == pytest.approx(EXPECTED[name]["red"], abs=0.002)
    low, high = profile.gray_card
    assert low - GRAY_CARD_MARGIN <= red <= high + GRAY_CARD_MARGIN
    assert gray_card_window_ok(profile)


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_the_lightest_gray_scale_step_sits_inside_the_sheets_window(stocks, name):
    profile = stocks[name]
    white = white_step_red_density(profile)
    assert white == pytest.approx(EXPECTED[name]["white"], abs=0.002)
    low, high = profile.white_step
    assert low - WHITE_STEP_MARGIN <= white <= high + WHITE_STEP_MARGIN
    assert white_step_window_ok(profile)
    # The sheet's forehead rows are a guide only; they are carried, light above dark.
    light, dark = profile.forehead["lightComplexion"], profile.forehead["darkComplexion"]
    assert light[0] > dark[0] and light[1] > dark[1]


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_iso_5800_speed_from_the_curves_is_within_half_a_stop_of_the_box(stocks, name):
    profile = stocks[name]
    speed = iso5800_speed(profile)
    assert speed == pytest.approx(EXPECTED[name]["speed"], abs=1.0)
    assert profile.box_speed == EXPECTED[name]["box"]
    assert abs(math.log2(speed / profile.box_speed)) <= 0.5


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_the_unmixing_fits_the_sheet_and_its_cross_talk_stays_bounded(stocks, name):
    model = stocks[name].negative_model
    assert model["rms"] < UNMIX_RMS_LIMIT
    cross = np.asarray(model["crossTalk"])
    assert cross[2, 1] < MAGENTA_TO_BLUE_LIMIT  # Status M blue per unit magenta
    assert cross[1, 0] < CYAN_TO_GREEN_LIMIT  # Status M green per unit cyan
    assert np.all(np.diag(cross) > 0.7) and np.all(cross >= -1e-9)


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_the_inversion_is_exact_and_the_amounts_do_not_fall(stocks, name):
    profile = stocks[name]
    free, held, pinned = inversion_residuals(profile)
    assert free < 1e-6
    assert held < 0.01  # toe rows where the sheet's two plots disagree by a few thousandths
    assert profile.amount_curves.min() >= 0.0
    assert largest_amount_fall(profile) <= 0.002 + largest_curve_fall(profile)
    # With the shoulder, the plotted peak sets the headroom rather than saturated grid corners.
    assert density_range(profile) == 2.5


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_the_curves_run_on_past_the_plot_at_their_last_slope(stocks, name):
    # The sheets stop plotting about 2.09 log H over mid-gray while every curve still rises
    # (docs/research/film-sim/scans.md section 4.1): no flat top there, and no roll-off either.
    profile = stocks[name]
    assert profile.plotted_to - mid_gray_log_exposure(profile.box_speed) == pytest.approx(2.09, abs=0.01)
    plotted = profile.log_exposure <= profile.plotted_to
    x, curves = profile.log_exposure[plotted], profile.curves[plotted]
    tail = [np.polyfit(x[-TOP_SLOPE_POINTS:], curves[-TOP_SLOPE_POINTS:, k], 1)[0] for k in range(3)]
    assert profile.top_slopes == pytest.approx(tail, abs=1e-9) and np.all(profile.top_slopes > 0.25)
    for step in (0.5, 1.0, 2.0):
        at = [np.interp(profile.plotted_to + step, profile.log_exposure, profile.curves[:, k]) for k in range(3)]
        assert at == pytest.approx(curves[-1] + step * profile.top_slopes, abs=1e-9)
    # The inversion holds on the extension too, and its amounts keep rising.
    assert inversion_residuals(profile)[0] < 1e-6
    assert np.all(np.diff(profile.amount_curves[~plotted], axis=0) > 0)
    # The Negative LUT's grid, couplers applied, never reaches the extension's end, where it is held.
    assert np.all(lut_layer_exposure_peak(profile) < profile.log_exposure[-1] - 0.1)


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_each_stock_turns_colour_into_exposure_through_its_fitted_matrix_and_keeps_grays_neutral(stocks, name):
    # Fitted to Morimoto et al.'s natural objects (CC BY 4.0) and NIST's forearms
    # (docs/research/film-sim/bakelook.md section 2), regularized by package G's criterion (matrix.md section 3);
    # the smooth basis stays for the synthetic stock.
    profile = stocks[name]
    matrix = exposure_matrix(profile)
    assert profile.exposure_matrix is not None and np.array_equal(matrix, profile.exposure_matrix)
    assert matrix.sum(axis=1) == pytest.approx(np.ones(3), abs=1e-5)
    assert not np.allclose(matrix, smooth_basis_matrix(profile), atol=0.05)
    # The red layer leans on the green primary the most: real reds, oranges and skins are step-like spectra.
    assert matrix[0, 0] > 1.2 and matrix[0, 1] < -0.2
    # Package G: no row as long as the unregularized fit's red rows (1.39 to 2.12), so input error is amplified less.
    assert np.all(np.linalg.norm(matrix, axis=1) < 1.9)
    for stops in (-4, -1, 0, 2, 4):
        x = log_exposure(profile, np.full(3, MID_GRAY * 2.0 ** stops))
        assert np.ptp(x) < 1e-6


@pytest.mark.parametrize("name", (*STOCK_NAMES, *NEW_STOCK_NAMES))
def test_every_gate_passes(stocks, name):
    gates = check_gates(stocks[name])
    assert [gate.name for gate in gates] == ["gray card", "white step", "ISO 5800 speed", "unmixing", "cross-talk", "inversion",
                                             "monotonic amounts", "density range"]
    assert all(gate.passed for gate in gates), [gate.detail for gate in gates if not gate.passed]


@pytest.mark.parametrize("name", (*STOCK_NAMES, *NEW_STOCK_NAMES))
def test_calibration_converges_on_endura_and_prints_mid_gray_neutral(stocks, endura, name):
    profile = stocks[name]
    printer = Printer(endura, profile.dyes, profile.base)
    gray = dye_amounts(profile, np.full(3, MID_GRAY))
    offsets = calibrate(printer, gray)
    assert printer(gray, offsets) == pytest.approx(np.full(3, GRAY_TARGET), abs=1e-6)
    per_unit = exposure_per_unit(printer, gray)
    assert np.all(per_unit > 0.6) and np.all(per_unit < 1.0)


def test_portra_400_regression_pin(stocks, endura):
    profile = stocks["portra400"]
    assert mid_gray_log_exposure(profile.box_speed) == pytest.approx(-1.5418, abs=0.001)
    assert gray_card_red_density(profile) == pytest.approx(0.835, abs=0.01)
    assert density_range(profile) == 2.5
    assert profile.negative_model["rms"] == pytest.approx(0.0061, abs=0.0005)
    reference = profile.log_exposure_reference
    assert reference == -1.44
    at_reference = [np.interp(reference, profile.log_exposure, profile.amount_curves[:, k]) for k in range(3)]
    assert at_reference == pytest.approx([0.918, 0.616, 0.994], abs=0.01)
    # The amounts at the plot's last point, and the straight line past it at the plotted slope.
    top = [np.interp(profile.plotted_to, profile.log_exposure, profile.amount_curves[:, k]) for k in range(3)]
    assert top == pytest.approx([2.437, 1.547, 2.319], abs=0.01)
    assert profile.top_slopes == pytest.approx([0.588, 0.546, 0.655], abs=0.005)
    printer = Printer(endura, profile.dyes, profile.base)
    gray = dye_amounts(profile, np.full(3, MID_GRAY))
    assert exposure_per_unit(printer, gray) == pytest.approx([0.843, 0.850, 0.812], abs=0.002)


@pytest.mark.parametrize("name", ("superia400", "pro400h", "c200"))
def test_fuji_uses_datasheet_curves_without_inventing_an_iso_speed_reference(stocks, name):
    profile = stocks[name]
    data = json.loads((STOCKS / f"{name}.json").read_text())
    assert profile.status == "datasheet" and data["source"]["url"].startswith("https://asset.fujifilm.com/")
    assert len(data["source"]["sha256"]) == 64
    assert profile.density_offset is not None and not profile.speed_reference
    assert np.all(profile.amount_curves[0] < 0.01)
    assert "not a speed reference" in check_gates(profile)[2].detail


def test_colorplus_is_an_explicit_proxy_and_not_a_duplicate_render(stocks):
    colorplus, gold = stocks["colorplus200"], stocks["gold200"]
    assert colorplus.status == "approximation"
    assert colorplus.grain_rms48 is None and colorplus.halation is None
    np.testing.assert_allclose(colorplus.curves, gold.curves)
    patch = np.array([0.35, 0.17, 0.09])
    assert not np.allclose(dye_amounts(colorplus, patch), dye_amounts(gold, patch), atol=0.005)


def test_portra_natural_preserves_portra_data_except_reduced_coupling(stocks):
    natural, portra = stocks["portra160natural"], stocks["portra160"]
    assert natural.status == "approximation"
    assert (natural.id, natural.display_name, natural.modelled_film) == (
        "kodak-portra-160-natural", "Portra Natural", "Kodak Portra 160")
    np.testing.assert_array_equal(natural.curves, portra.curves)
    np.testing.assert_array_equal(natural.dyes, portra.dyes)
    np.testing.assert_allclose(natural.couplers, np.round(portra.couplers * 0.6, 4), rtol=0, atol=0)
    original = json.loads((STOCKS / "portra160.json").read_text())
    reduced = json.loads((STOCKS / "portra160natural.json").read_text())
    for key in ("id", "displayName", "status", "notes"):
        original.pop(key)
        reduced.pop(key)
    original["couplers"]["interLayer"] = np.round(portra.couplers * 0.6, 4).tolist()
    assert reduced == original


def test_portra_natural_reduces_skin_chroma_without_losing_checker_accuracy(stocks):
    rgb, reference = scene()
    portra = render(stocks["portra160"], rgb)
    natural = render(stocks["portra160natural"], rgb)
    assert np.all(np.hypot(natural[:2, 1], natural[:2, 2]) < np.hypot(portra[:2, 1], portra[:2, 2]))
    assert abs(np.median(delta_e_2000(natural, reference)) - np.median(delta_e_2000(portra, reference))) <= 0.5


def test_tungsten_stocks_use_distinct_published_curves_and_halos(stocks):
    vision, cine = stocks["vision3500t"], stocks["cinestill800t"]
    assert (vision.status, cine.status) == ("datasheet", "approximation")
    assert (vision.box_speed, cine.box_speed) == (500, 800)
    assert vision.grain_rms48 is not None and cine.grain_rms48 is None
    np.testing.assert_array_equal(vision.dyes, cine.dyes)
    np.testing.assert_array_equal(vision.sensitivity, cine.sensitivity)
    assert np.max(np.abs(vision.curves - cine.curves)) > 0.15
    assert cine.halation["strength"] > 5 * vision.halation["strength"] > 0
    assert cine.halation["radiusMicrometres"] > vision.halation["radiusMicrometres"]
    assert cine.halation["greenShare"] < vision.halation["greenShare"]


@pytest.mark.parametrize("name", ("vision3500t", "cinestill800t"))
def test_tungsten_calibration_preserves_the_published_highlight_curve(stocks, name):
    profile = stocks[name]
    assert profile.capture_illuminant_kelvin == 3200
    assert not profile.speed_reference and profile.has_published_shoulder
    assert not np.allclose(exposure_matrix(profile),
                           exposure_matrix(dataclasses.replace(profile, capture_illuminant_kelvin=None)), atol=0.05)
    stops = np.array([0.0, 4.0, 6.0, 8.0])
    rgb = np.repeat((MID_GRAY * np.exp2(stops))[:, None], 3, axis=1)
    log_h = mid_gray_log_exposure(profile.box_speed) + stops * math.log10(2)
    expected = np.stack([np.interp(log_h, profile.log_exposure, curve) for curve in profile.amount_curves.T], axis=1)
    np.testing.assert_allclose(dye_amounts(profile, rgb), expected, atol=1e-6)
    assert np.all(expected[3] - expected[2] < expected[2] - expected[1])
    assert np.all(expected[3] - expected[2] > 0.05)


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_the_couplers_meet_the_gamma_ratios_published_for_the_stocks_class(stocks, name):
    published = json.loads((STOCKS / f"{name}.json").read_text())["couplers"]["gammaRatios"]
    np.testing.assert_allclose(gamma_ratios(stocks[name]), published, atol=0.005)
    # With no couplers the green record's gamma ratio is far below any published film's.
    uncoupled = dataclasses.replace(stocks[name], couplers=np.zeros((3, 3)))
    assert gamma_ratios(uncoupled)[1] < 0.75


def test_saturation_follows_what_kodak_says_of_each_stock(stocks):
    # Ektar: "high saturation and ultra-vivid color"; Portra 160 the natural one; Gold and UltraMax
    # Kodak's consumer films; Portra 400 and 800 between (docs/research/film.md section 4.2).
    rgb, scene_lab = scene()
    scene_chroma = np.hypot(scene_lab[COLOURED, 1], scene_lab[COLOURED, 2])
    chroma = {}
    for name in STOCK_NAMES:
        lab = render(stocks[name], rgb)
        chroma[name] = float(np.mean(np.hypot(lab[COLOURED, 1], lab[COLOURED, 2]) / scene_chroma))
        assert np.hypot(*lab[NEUTRAL_5, 1:]) < 1.0  # the gray axis stays neutral
    assert chroma["portra160"] < min(chroma["portra400"], chroma["portra800"])
    assert max(chroma["portra400"], chroma["portra800"]) < min(chroma["gold200"], chroma["ultramax400"])
    assert max(chroma["gold200"], chroma["ultramax400"]) < chroma["ektar100"]


# Kodak's own ranking of the four KODAK PROFESSIONAL colour negatives, the same in two independent
# publications: the 2023 KODAK PROFESSIONAL catalogue (page 2) and the 2017 "KODAK PROFESSIONAL Color
# Negative Films" brochure, each with four bars, saturation, contrast, granularity and sharpness
# (docs/research/film-sim/commercial.md section 4.1, measure.md section 3.4). Ordinal facts only.
KODAK_PROFESSIONAL = ("portra160", "portra400", "portra800", "ektar100")
# Portra 800's couplers were raised so it clears Portra 400 by 0.02 (docs/research/film-sim/bakelook.md
# section 4); the test allows a quarter of that to rounding.
SATURATION_MARGIN = 0.015
# The catalogue draws the three Portras' contrast at one point (0.28 of the bar) and Ektar's at 0.54.
PORTRA_CONTRAST_TOLERANCE = 0.05  # relative spread of the Portras' print L* per stop
EKTAR_CONTRAST_LEAD = 0.05  # Ektar at least this much above the steepest Portra


def _print_lstar_per_stop(profile):
    """Print L* per stop at mid-gray, half a stop either side, at the daylight reference."""
    lab = render(profile, np.array([np.full(3, MID_GRAY * 2.0 ** e) for e in (-0.5, 0.5)]))
    return float(lab[1, 0] - lab[0, 0])


def test_saturation_follows_kodaks_catalogue_and_brochure(stocks):
    # Both rank colour saturation Portra 160 < Portra 400 < Portra 800 < Ektar 100.
    rgb, scene_lab = scene()
    scene_chroma = np.hypot(scene_lab[COLOURED, 1], scene_lab[COLOURED, 2])
    chroma = {}
    for name in KODAK_PROFESSIONAL:
        lab = render(stocks[name], rgb)
        chroma[name] = float(np.mean(np.hypot(lab[COLOURED, 1], lab[COLOURED, 2]) / scene_chroma))
    assert chroma["portra160"] < chroma["portra400"]
    assert chroma["portra400"] + SATURATION_MARGIN < chroma["portra800"] < chroma["ektar100"]


def test_contrast_follows_kodaks_catalogue_and_brochure(stocks):
    # Both draw the three Portras' contrast the same and Ektar 100's higher.
    slope = {name: _print_lstar_per_stop(stocks[name]) for name in KODAK_PROFESSIONAL}
    portras = [slope[name] for name in KODAK_PROFESSIONAL[:3]]
    assert (max(portras) - min(portras)) / min(portras) < PORTRA_CONTRAST_TOLERANCE
    assert slope["ektar100"] > max(portras) * (1 + EKTAR_CONTRAST_LEAD)


def test_granularity_follows_kodaks_catalogue_and_brochure(stocks):
    # Both rank granularity Portra 800 coarsest, then 400, 160, and Ektar 100 finest; the profiles'
    # RMS granularity, anchored on the sheets' Print Grain Index, keeps that order in every layer.
    rms = {name: stocks[name].grain_rms48 for name in KODAK_PROFESSIONAL}
    for layer in range(3):
        assert rms["portra800"][layer] > rms["portra400"][layer] > rms["portra160"][layer] > rms["ektar100"][layer]


def test_portra_800s_targets_stay_inside_its_class_and_below_ektar():
    # The Portras' class runs from "natural" (NPH 400's green and blue) to KODAK MAX 400 (EP1693702A1
    # Table 3; film.md 4.2); Ektar 100 takes KODAK HD 400's, which Portra 800 must stay strictly under.
    target = {name: np.array(json.loads((STOCKS / f"{name}.json").read_text())["couplers"]["gammaRatios"])
              for name in ("portra400", "portra800", "ektar100")}
    natural, max400 = np.array([1.36, 1.27, 0.97]), np.array([1.36, 1.61, 1.29])
    assert np.all(natural <= target["portra800"]) and np.all(target["portra800"] <= max400)
    assert np.all(target["portra800"] >= target["portra400"]) and np.all(target["portra800"] < target["ektar100"])
