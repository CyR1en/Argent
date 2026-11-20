import dataclasses

import numpy as np
import pytest

from argent_bake import synthetic
from argent_bake.negative import MID_GRAY, dye_amounts
from argent_bake.printing import (CalibrationError, GRAY_TARGET, PaperModel, Printer, bake_print, calibrate,
                                  exposure_per_unit)
from argent_bake.spectral import WAVELENGTHS

profile = synthetic.profile()
paper = synthetic.paper()
printer = Printer(paper, profile.dyes, profile.base)
gray_amounts = dye_amounts(profile, np.full(3, MID_GRAY))


def flat_paper(**changes) -> PaperModel:
    """The synthetic paper with its curves replaced, for isolating one stage of the model."""
    return dataclasses.replace(paper, **changes)


def test_calibration_prints_mid_gray_as_a_neutral_target():
    offsets = calibrate(printer, gray_amounts)
    assert printer(gray_amounts, offsets) == pytest.approx(np.full(3, GRAY_TARGET), abs=1e-7)


def test_calibration_is_independent_of_where_it_starts_looking():
    # Different negatives need different filtration; each must still print its own gray neutral.
    for shift in (-0.3, 0.0, 0.4):
        amounts = gray_amounts + shift
        offsets = calibrate(printer, amounts)
        assert printer(amounts, offsets) == pytest.approx(np.full(3, GRAY_TARGET), abs=1e-6)


def test_calibration_fails_loudly_when_the_paper_cannot_reach_the_target():
    dim = flat_paper(curves=np.full_like(paper.curves, 3.0))  # paper that is black at any exposure
    with pytest.raises((CalibrationError, np.linalg.LinAlgError)):
        calibrate(Printer(dim, profile.dyes, profile.base), gray_amounts)


def test_a_clear_print_is_paper_white():
    # No paper dye: reflectance one everywhere, which must map to equal Rec. 2020 RGB of one.
    clear = flat_paper(curves=np.zeros_like(paper.curves))
    rgb = Printer(clear, profile.dyes, profile.base)(gray_amounts, np.zeros(3))
    assert rgb == pytest.approx(np.ones(3), abs=1e-9)


def test_paper_dyes_subtract_the_light_they_absorb():
    # Only the cyan layer holds dye. Cyan absorbs red, so red falls and the rest stay high.
    curves = np.zeros_like(paper.curves)
    curves[:, 0] = 1.0
    rgb = Printer(flat_paper(curves=curves), profile.dyes, profile.base)(gray_amounts, np.zeros(3))
    assert rgb[0] < 0.25 < rgb[1] and rgb[2] > 0.5

    curves = np.zeros_like(paper.curves)
    curves[:, 2] = 1.0  # yellow absorbs blue
    rgb = Printer(flat_paper(curves=curves), profile.dyes, profile.base)(gray_amounts, np.zeros(3))
    assert rgb[2] < 0.25 < rgb[0] and rgb[1] > 0.5


def test_the_negative_base_absorbs_light_before_the_paper_sees_it():
    base = 0.3 + 0.4 * np.exp(-0.5 * ((WAVELENGTHS - 440.0) / 40.0) ** 2)  # an orange mask
    with_base = Printer(paper, profile.dyes, base).log_exposure(gray_amounts)
    without = printer.log_exposure(gray_amounts)
    assert np.all(with_base < without)
    assert without[2] - with_base[2] > without[0] - with_base[0]  # the blue layer loses the most


def test_denser_negatives_print_lighter_on_every_channel():
    offsets = calibrate(printer, gray_amounts)
    for channel in range(3):
        low, high = gray_amounts.copy(), gray_amounts.copy()
        high[channel] += 0.3
        assert printer(high, offsets)[channel] > printer(low, offsets)[channel]


def test_shifting_all_amounts_is_a_print_exposure_change():
    offsets = calibrate(printer, gray_amounts)
    lighter = printer(gray_amounts + np.log10(2), offsets)  # one stop less light through the negative
    assert np.all(lighter > GRAY_TARGET)
    assert np.all(printer(gray_amounts - np.log10(2), offsets) < GRAY_TARGET)


def test_exposure_per_unit_is_the_slope_of_paper_exposure_against_each_dye():
    per_unit = exposure_per_unit(printer, gray_amounts)
    assert per_unit.shape == (3,) and np.all(per_unit > 0.3) and np.all(per_unit < 1.2)
    for k in range(3):
        step = np.zeros(3)
        step[k] = 0.01
        slope = (printer.log_exposure(gray_amounts + step) - printer.log_exposure(gray_amounts - step))[k] / 0.02
        assert per_unit[k] == pytest.approx(-slope, abs=1e-3)  # more dye, less exposure


def test_baked_print_lut_orientation_and_range():
    offsets = calibrate(printer, gray_amounts)
    lut = bake_print(printer, 9, 3.0, offsets)
    assert lut.shape == (9, 9, 9, 3)
    assert lut.min() >= 0.0
    # Indexed [blue][green][red]; each axis mostly drives its own output channel.
    for axis, channel in ((2, 0), (1, 1), (0, 2)):
        index = [0, 0, 0]
        index[axis] = 8
        own = lut[tuple(index)][channel] - lut[0, 0, 0][channel]
        others = [abs(lut[tuple(index)][c] - lut[0, 0, 0][c]) for c in range(3) if c != channel]
        assert own > 0 and own > 2 * max(others), (axis, channel, own, others)


def test_baked_print_lut_is_darkest_at_zero_amount_and_lightest_at_the_top():
    offsets = calibrate(printer, gray_amounts)
    lut = bake_print(printer, 9, 3.0, offsets)
    assert lut[0, 0, 0].max() < 0.05
    assert lut[-1, -1, -1].min() > 0.75


def test_chunking_does_not_change_the_result_beyond_rounding(monkeypatch):
    import argent_bake.printing as printing
    offsets = calibrate(printer, gray_amounts)
    whole = bake_print(printer, 9, 3.0, offsets)
    monkeypatch.setattr(printing, "CHUNK", 100)  # a different batch size reorders BLAS sums in the last bits
    assert printing.bake_print(printer, 9, 3.0, offsets) == pytest.approx(whole, rel=1e-12, abs=1e-14)


def test_the_wavelength_grid_is_what_the_models_expect():
    assert paper.sensitivity.shape[0] == paper.enlarger.shape[0] == paper.viewing.shape[0] == WAVELENGTHS.size
