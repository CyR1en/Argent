import numpy as np
import pytest

from argent_bake.negative import REFERENCE_ILLUMINANT, SMOOTHNESS_RIDGE, reflectance_basis
from argent_bake.spectral import (D50, D55, D65, D65_XY, WAVELENGTHS, adaptation_matrix, blackbody, cie_1931,
                                  daylight, gaussian, load_data_table, resample, resample_hold, resample_log,
                                  rgb_to_xyz_matrix, white_point, xy_to_xyz)


def test_observer_is_the_tabulated_cie_1931_table():
    cmf = cie_1931()
    assert cmf.shape == (81, 3)
    assert WAVELENGTHS[cmf[:, 1].argmax()] == 555 and cmf[:, 1].max() == 1.0
    assert cmf[WAVELENGTHS == 380][0] == pytest.approx((0.001368, 0.000039, 0.006450001))
    # Column sums on the 5 nm grid, measured in Phase 1.
    assert cmf.sum(axis=0) == pytest.approx(np.full(3, 21.37), abs=0.01)


def test_the_data_files_carry_their_notice():
    from argent_bake.spectral import CMF_TABLE, DAYLIGHT_TABLE, load_data_text
    for name in (CMF_TABLE, DAYLIGHT_TABLE):
        first = load_data_text(name).splitlines()[0]
        assert first.startswith("#") and "CC BY-SA 4.0" in first and "sha256" in first and "Changes:" in first
    assert load_data_table(DAYLIGHT_TABLE).shape == (107, 4)


def test_observer_resamples_onto_another_grid_and_is_zero_outside():
    fine = np.arange(300.0, 900.0, 1.0)
    cmf = cie_1931(fine)
    assert cmf[fine == 555, 1][0] == 1.0
    assert cmf[fine == 557.5, 1].size == 0 and cmf[fine == 557, 1][0] == pytest.approx(0.5 * (1.0 + 0.9949501), abs=2e-3)
    assert np.all(cmf[fine < 380] == 0) and np.all(cmf[fine > 780] == 0)


@pytest.mark.parametrize("cct, x, z, tolerance", [(5003.0, 96.42, 82.51, 0.02), (5503.0, 95.68, 92.14, 0.02),
                                                  (6504.0, 95.04, 108.88, 0.05)])
def test_daylight_white_points_match_the_d_series(cct, x, z, tolerance):
    # D50 and D55, the two the bake uses as spectra, within 0.02 of the published white points. The
    # formula's D65 differs from CIE's own D65 table by up to 0.046 (measured in Phase 1); the bake
    # only uses D65 as a chromaticity for the Rec. 2020 matrix.
    xyz = white_point(daylight(cct)) * 100.0
    assert xyz[0] == pytest.approx(x, abs=tolerance) and xyz[2] == pytest.approx(z, abs=tolerance)


def test_daylight_is_normalized_at_560_and_the_constants_are_the_d_series():
    assert daylight(5503.0)[WAVELENGTHS == 560.0][0] == 100.0
    assert np.array_equal(D50, daylight(5003.0)) and np.array_equal(D55, daylight(5503.0)) and np.array_equal(D65, daylight(6504.0))
    assert REFERENCE_ILLUMINANT is D55 or np.array_equal(REFERENCE_ILLUMINANT, D55)
    with pytest.raises(ValueError):
        daylight(3000.0)


def test_daylight_above_7000_k_uses_the_second_polynomial_and_stays_continuous():
    below, above = white_point(daylight(6999.0)), white_point(daylight(7001.0))
    assert below == pytest.approx(above, abs=2e-3)


def test_blackbody_follows_planck():
    # Wien's law: the peak of a 5500 K body is near 527 nm per unit wavelength.
    wl = np.arange(300.0, 1200.0, 1.0)
    assert wl[blackbody(5500.0, wl).argmax()] == pytest.approx(527, abs=3)
    assert blackbody(3200.0)[WAVELENGTHS == 560.0][0] == pytest.approx(1.0)
    # A tungsten lamp is redder than daylight: more red than blue.
    tungsten = blackbody(3200.0)
    assert tungsten[WAVELENGTHS == 650.0][0] > 2 * tungsten[WAVELENGTHS == 450.0][0]


def test_rec2020_matrix_maps_white_to_the_given_white():
    white = xy_to_xyz(*D65_XY)
    matrix = rgb_to_xyz_matrix()
    assert matrix @ np.ones(3) == pytest.approx(white)
    # Rec. 2020 red has the chromaticity the standard says.
    red = matrix @ np.array([1.0, 0.0, 0.0])
    assert red[0] / red.sum() == pytest.approx(0.708, abs=1e-6)
    assert red[1] / red.sum() == pytest.approx(0.292, abs=1e-6)


def test_bradford_adaptation_moves_the_source_white_to_the_destination():
    source = white_point(D50)
    destination = xy_to_xyz(*D65_XY)
    assert adaptation_matrix(source, destination) @ source == pytest.approx(destination)
    assert adaptation_matrix(destination, destination) == pytest.approx(np.eye(3))


def test_resample_is_zero_outside_the_measured_range():
    source = np.array([400.0, 500.0, 600.0])
    out = resample(source, np.array([1.0, 2.0, 3.0]))
    assert out[WAVELENGTHS == 380.0][0] == 0.0
    assert out[WAVELENGTHS == 450.0][0] == pytest.approx(1.5)
    assert out[WAVELENGTHS == 700.0][0] == 0.0


def test_resample_hold_keeps_the_end_values_outside():
    source = np.array([400.0, 500.0, 600.0])
    out = resample_hold(source, np.array([1.0, 2.0, 3.0]))
    assert out[WAVELENGTHS == 380.0][0] == 1.0 and out[WAVELENGTHS == 780.0][0] == 3.0
    assert out[WAVELENGTHS == 450.0][0] == pytest.approx(1.5)


def test_resample_log_interpolates_in_the_log_domain_and_returns_linear():
    source = np.array([400.0, 600.0])
    out = resample_log(source, np.array([0.0, -2.0]))
    assert out[WAVELENGTHS == 500.0][0] == pytest.approx(0.1)  # halfway in log, not 0.505
    assert out[WAVELENGTHS == 400.0][0] == pytest.approx(1.0)
    assert out[WAVELENGTHS == 390.0][0] == 0.0 and out[WAVELENGTHS == 650.0][0] == 0.0


def test_resample_log_treats_a_null_as_no_response_and_never_interpolates_across_it():
    source = np.array([400.0, 410.0, 420.0, 430.0])
    out = resample_log(source, np.array([0.0, np.nan, np.nan, 0.0]))
    assert out[WAVELENGTHS == 400.0][0] == 1.0 and out[WAVELENGTHS == 430.0][0] == 1.0
    assert out[WAVELENGTHS == 405.0][0] == 0.0 and out[WAVELENGTHS == 415.0][0] == 0.0 and out[WAVELENGTHS == 425.0][0] == 0.0


def test_gaussian_has_unit_peak():
    assert gaussian(550.0, 30.0).max() == pytest.approx(1.0)


class TestReflectanceBasis:
    def test_columns_sum_to_a_flat_spectrum(self):
        assert reflectance_basis().sum(axis=1) == pytest.approx(np.ones(WAVELENGTHS.size), abs=1e-9)

    def test_each_primary_keeps_its_tristimulus(self):
        basis = reflectance_basis()
        cmf = cie_1931()
        weights = cmf * REFERENCE_ILLUMINANT[:, None] / (cmf[:, 1] @ REFERENCE_ILLUMINANT)
        to_xyz = rgb_to_xyz_matrix(white_xyz=white_point(REFERENCE_ILLUMINANT))
        assert weights.T @ basis == pytest.approx(to_xyz, abs=1e-9)

    def test_spectra_stay_tame(self):
        # The ridge exists to stop the narrow Rec. 2020 primaries from swinging to -4.
        basis = reflectance_basis()
        assert basis.min() > -0.7 and basis.max() < 1.6, SMOOTHNESS_RIDGE
