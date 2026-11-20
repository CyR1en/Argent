import numpy as np
import pytest

from argent_bake.densitometry import (dye_amounts_for, invert_curves, status_density, status_jacobian,
                                      status_weights)
from argent_bake.spectral import WAVELENGTHS, gaussian


def test_weights_are_normalized_and_peak_where_the_standard_says():
    for kind, peaks in (("M", (640, 540, 450)), ("A", (620, 530, 440))):
        w = status_weights(kind)
        assert w.shape == (81, 3)
        assert w.sum(axis=0) == pytest.approx(np.ones(3))
        assert tuple(WAVELENGTHS[w.argmax(axis=0)]) == peaks
    with pytest.raises(ValueError):
        status_weights("T")


def test_weights_extend_beyond_the_table_with_the_end_slopes():
    # Status M red: table ends at 770 nm with -0.040 log10 per nm beyond it, so 780 nm is 0.4 log lower.
    w = status_weights("M")
    red_770, red_780 = w[WAVELENGTHS == 770.0, 0][0], w[WAVELENGTHS == 780.0, 0][0]
    assert np.log10(red_770 / red_780) == pytest.approx(0.4)
    # Status M blue: 400 nm sits 10 nm below the first entry at 410 with +0.250 per nm.
    blue_400, blue_410 = w[WAVELENGTHS == 400.0, 2][0], w[WAVELENGTHS == 410.0, 2][0]
    assert np.log10(blue_410 / blue_400) == pytest.approx(2.5)


def test_a_flat_density_reads_as_itself():
    for kind in ("A", "M"):
        assert status_density(np.full(81, 1.3), status_weights(kind)) == pytest.approx(np.full(3, 1.3))
    stack = np.stack([np.full(81, 0.5), np.full(81, 2.0)])
    np.testing.assert_allclose(status_density(stack, status_weights("M")), [[0.5] * 3, [2.0] * 3])


def test_status_m_of_the_portra_400_minimum_density_spectrum(stocks):
    # Measured in Phase 1 on the reviewed extraction: 0.195, 0.622, 0.800.
    assert status_density(stocks["portra400"].base, status_weights("M")) == pytest.approx([0.195, 0.622, 0.800], abs=0.003)


def test_status_a_cross_talk_of_the_endura_dyes(endura):
    # Phase 1, rows R, G, B and columns C, M, Y, dye spectra held at their end values.
    matrix = np.stack([status_density(endura.dyes[:, k], status_weights("A")) for k in range(3)], axis=1)
    expected = [[0.9156, 0.0609, 0.0095], [0.1023, 0.8922, 0.0874], [0.0358, 0.0801, 0.9617]]
    np.testing.assert_allclose(matrix, expected, atol=0.003)


def test_the_jacobian_matches_finite_differences():
    weights = status_weights("M")
    dyes = np.stack([gaussian(650, 50), gaussian(545, 40), gaussian(445, 35)], axis=1)
    base = 0.1 + 0.2 * gaussian(430, 60)
    amounts = np.array([0.8, 0.6, 0.9])
    analytic = status_jacobian(base + dyes @ amounts, weights, dyes)
    numeric = np.empty((3, 3))
    for k in range(3):
        step = np.zeros(3)
        step[k] = 1e-6
        numeric[:, k] = (status_density(base + dyes @ (amounts + step), weights)
                         - status_density(base + dyes @ (amounts - step), weights)) / 2e-6
    assert analytic == pytest.approx(numeric, abs=1e-7)


def test_inversion_recovers_known_amounts_and_pins_at_zero_when_it_must():
    weights = status_weights("M")
    dyes = np.stack([gaussian(650, 50), gaussian(545, 40), gaussian(445, 35)], axis=1)
    base = 0.15 + 0.3 * gaussian(430, 60)
    truth = np.array([[0.0, 0.0, 0.0], [0.2, 0.1, 0.4], [1.2, 0.9, 1.5], [2.4, 1.7, 2.3]])
    targets = status_density(base[None, :] + truth @ dyes.T, weights)
    amounts, residuals = invert_curves(targets, base, dyes, weights)
    assert amounts == pytest.approx(truth, abs=1e-7)
    assert np.abs(residuals).max() < 1e-9
    # A target below what the base reads in one channel cannot be met: that amount pins at zero.
    low = status_density(base, weights) - np.array([0.05, 0.0, 0.0])
    a, r, _ = dye_amounts_for(low, base, dyes, weights)
    assert a[0] == 0.0 and a.min() >= 0.0 and abs(r[0]) > 0.01 and np.abs(r[1:]).max() < 1e-6



def test_the_solver_never_ends_worse_than_it_started():
    # Overlapping dyes and a warm start where a blocked step's line search fails. The old
    # solver zeroed the blocked amount before that search and returned it anyway, reading
    # 0.255 from a start that read 0.170; the amounts that come back must never be worse.
    weights = status_weights("M")
    dyes = np.stack([gaussian(637.1010199227926, 62.52916396), gaussian(594.5115366205181, 50.67820896),
                     gaussian(480.37862688123073, 78.30342295)], axis=1)
    base = 0.1 + 0.6 * gaussian(584.456434672987, 80)
    target = status_density(base, weights) + np.array([0.40079926, 0.26497539, 0.1914984])
    start = np.array([0.15136708, 0.46260069, 0.18058594])
    before = np.linalg.norm(status_density(base + dyes @ start, weights) - target)
    amounts, residual, _ = dye_amounts_for(target, base, dyes, weights, start)
    assert amounts.min() >= 0.0
    assert np.linalg.norm(residual) <= before
    assert np.linalg.norm(residual) < 0.02
    assert residual == pytest.approx(status_density(base + dyes @ amounts, weights) - target)
