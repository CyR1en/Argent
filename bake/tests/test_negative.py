import math

import numpy as np
import pytest

from argent_bake import synthetic
from argent_bake.densitometry import status_density, status_weights
from argent_bake.encoding import LogEncoding
from argent_bake.negative import (GRAY_CARD_FACTOR, LENS_FACTOR, METER_CONSTANT, MID_GRAY, bake_negative,
                                  check_gates, density_range, density_range_for, dye_amounts, exposure_matrix,
                                  gray_card_red_density, gray_card_window_ok, input_grid, iso5800_speed,
                                  log_exposure, mid_gray_log_exposure, shoulder_log_exposure)

profile = synthetic.profile()


def gray(stops):
    return np.stack([MID_GRAY * 2.0 ** np.asarray(stops, dtype=float)] * 3, axis=-1)


def test_highlight_shoulder_keeps_unit_slope_at_the_knee_and_flattens_smoothly():
    mid = mid_gray_log_exposure(400)
    log2 = math.log10(2)
    ev = np.array([-8, 0, 2, 3, 3.0001, 4, 5, 6, 7, 8, 40])
    effective = (shoulder_log_exposure(mid + ev * log2, mid) - mid) / log2
    np.testing.assert_allclose(effective[:4], ev[:4], atol=1e-12)
    assert (effective[4] - effective[3]) / (ev[4] - ev[3]) == pytest.approx(1, rel=1e-4)
    per_stop = np.diff(effective[5:10])
    assert np.all(per_stop > 0.0) and np.all(np.diff(per_stop) < 0.0)
    assert effective[9] < 5.5 and effective[-1] == pytest.approx(5.5, abs=1e-6)


def test_mid_gray_is_placed_half_a_stop_above_the_meter_equation():
    # ISO 2720 gives 0.65 * 12.5 / S; Kodak's gray-card instructions add half a stop: 11.49 / S lux-seconds.
    assert GRAY_CARD_FACTOR == pytest.approx(math.sqrt(2))
    assert 10 ** mid_gray_log_exposure(400) == pytest.approx(LENS_FACTOR * METER_CONSTANT * math.sqrt(2) / 400)
    assert 10 ** mid_gray_log_exposure(400) * 400 == pytest.approx(11.49, abs=0.005)
    assert mid_gray_log_exposure(400) == pytest.approx(-1.5418, abs=0.001)
    assert mid_gray_log_exposure(100) - mid_gray_log_exposure(400) == pytest.approx(np.log10(4))


def test_neutrals_expose_every_layer_equally():
    for stops in (-6, -2, 0, 1, 3):
        x = log_exposure(profile, gray(stops))
        assert x[0] == pytest.approx(x[1]) == pytest.approx(x[2])
        assert x[0] == pytest.approx(mid_gray_log_exposure(400) + stops * np.log10(2))


def test_a_stop_is_log10_of_two_on_the_exposure_axis():
    steps = np.diff(log_exposure(profile, gray(np.arange(-4, 5))), axis=0)
    assert steps == pytest.approx(np.full_like(steps, np.log10(2)))


def test_exposure_matrix_is_close_to_diagonal_for_the_synthetic_stock():
    matrix = exposure_matrix(profile)
    share = matrix / matrix.sum(axis=1, keepdims=True)
    assert np.all(np.diag(share) > 0.8)
    assert np.all(share > -0.15)


def test_amounts_rise_with_exposure_on_every_dye():
    a = dye_amounts(profile, gray(np.arange(-8, 5)))
    assert np.all(np.diff(a, axis=0) > 0)


def test_the_toe_is_flat_at_the_inverted_minimum():
    a = dye_amounts(profile, gray(-8))
    assert a == pytest.approx(profile.amount_curves[0], abs=0.12)


def test_mid_gray_lands_on_the_straight_part_of_the_curve():
    mid = mid_gray_log_exposure(400)
    status = np.array([np.interp(mid, profile.log_exposure, profile.curves[:, k]) for k in range(3)])
    assert status - profile.curves.min(axis=0) == pytest.approx(np.full(3, synthetic.MID_GRAY_NET), abs=0.03)
    # On the gray axis the amounts are the inverted curves at mid-gray, couplers or not.
    expected = np.array([np.interp(mid, profile.log_exposure, profile.amount_curves[:, k]) for k in range(3)])
    assert dye_amounts(profile, gray(0)) == pytest.approx(expected, abs=1e-9)


def test_amounts_reproduce_the_status_m_curves_through_the_densitometer():
    weights = status_weights("M")
    reproduced = status_density(profile.base[None, :] + profile.amount_curves @ profile.dyes.T, weights)
    assert reproduced == pytest.approx(profile.curves, abs=1e-8)
    assert profile.inversion_residual < 1e-8


def test_the_gray_axis_is_untouched_by_the_couplers():
    uncoupled = profile.__class__(**{**profile.__dict__, "couplers": np.zeros((3, 3))})
    ramp = gray(np.arange(-6, 5))
    assert dye_amounts(profile, ramp) == pytest.approx(dye_amounts(uncoupled, ramp), abs=1e-9)


def test_couplers_raise_saturation_and_keep_amounts_monotonic():
    uncoupled = profile.__class__(**{**profile.__dict__, "couplers": np.zeros((3, 3))})
    red = np.array([0.40, 0.03, 0.03])
    with_couplers, without = dye_amounts(profile, red), dye_amounts(uncoupled, red)
    # A red object exposes the red layer hard. Coupling pushes the other layers down and the red layer up.
    assert with_couplers[0] - with_couplers[1] > without[0] - without[1]
    assert with_couplers[1] < without[1] and with_couplers[2] < without[2]

    ramp = np.stack([np.linspace(0.01, 1.0, 50), np.full(50, 0.05), np.full(50, 0.05)], axis=-1)
    assert np.all(np.diff(dye_amounts(profile, ramp)[:, 0]) > 0)


@pytest.mark.parametrize("peak, expected", [(0.2, 0.5), (0.5, 0.5), (2.2, 2.5), (2.5, 2.5), (2.51, 3.0), (3.0, 3.0)])
def test_density_range_rounds_up_to_half_a_unit(peak, expected):
    assert density_range_for(peak) == expected


def test_input_grid_runs_red_fastest_and_follows_the_log_encoding():
    encoding = LogEncoding()
    assert encoding.stops_above_mid_gray == 5.0 and encoding.stops_below_mid_gray == 8.0
    grid = input_grid(5, encoding)
    assert grid.shape == (5, 5, 5, 3)
    flat = grid.reshape(-1, 3)
    # .cube order: the first axis changes red, so row 1 differs from row 0 only in red.
    assert flat[1, 0] > flat[0, 0] and flat[1, 1] == flat[0, 1] and flat[1, 2] == flat[0, 2]
    assert flat[5, 1] > flat[0, 1] and flat[5, 0] == flat[0, 0]
    assert flat[25, 2] > flat[0, 2] and flat[25, 1] == flat[0, 1]
    assert flat[0] == pytest.approx(np.full(3, encoding.decode(0.0)))
    assert flat[-1] == pytest.approx(np.full(3, encoding.decode(1.0)))
    assert flat[-1] == pytest.approx(np.full(3, MID_GRAY * 32.0))


def test_baked_lut_is_normalized_to_the_largest_amount_on_the_plot_or_the_grid():
    bake = bake_negative(profile, 9)
    assert bake.lut.shape == (9, 9, 9, 3)
    assert bake.lut.min() > 0 and bake.lut.max() <= 1.0
    assert bake.lut.max() > 0.5  # the range is tight, not wasteful
    plotted = profile.amount_curves[profile.log_exposure <= profile.plotted_to]
    grid = dye_amounts(profile, input_grid(9, LogEncoding()))
    assert bake.density_range == density_range(profile, 9) == density_range_for(max(plotted.max(), grid.max()))
    assert bake.density_range % 0.5 == 0


def test_the_synthetic_gates_pass_and_the_sheet_only_ones_are_informational():
    assert gray_card_window_ok(profile)
    low, high = profile.gray_card
    assert low <= gray_card_red_density(profile) <= high
    assert iso5800_speed(profile) > 0
    gates = check_gates(profile)
    assert all(gate.passed for gate in gates)
    by_name = {gate.name: gate for gate in gates}
    assert "informational" in by_name["ISO 5800 speed"].detail and "informational" in by_name["cross-talk"].detail
