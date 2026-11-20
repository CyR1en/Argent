import numpy as np
import pytest

from argent_bake.gamut import (LIMITS, POWER, RGB_TO_XYZ, THRESHOLD,
                               XYZ_TO_RGB, compress, limits_for)
from argent_bake.spectral import cie_1931


def test_derived_limits_match_pinned_constants():
    assert tuple(np.round(limits_for(), 4)) == LIMITS
    assert THRESHOLD == (0.90, 0.90, 0.90)
    assert POWER == 1.2
    assert np.all(limits_for() > THRESHOLD)


def test_in_threshold_is_bit_identical():
    rgb = np.array([[1, .1, .4], [.25, .25, .25], [0, 0, 0],
                    [-1, -2, -3], [0, -2, -1]], dtype=np.float32)
    result = compress(rgb)
    assert result.dtype == rgb.dtype
    assert result.tobytes() == rgb.tobytes()
    zero = np.array([-0., 0., -0.])
    assert compress(zero).tobytes() == zero.tobytes()


def test_limit_lands_on_edge():
    limits = LIMITS
    for channel in range(3):
        rgb = np.ones(3)
        rgb[channel] = 1 - limits[channel]
        out = compress(rgb, THRESHOLD, limits)
        assert out[channel] == pytest.approx(0, abs=1e-6)
        assert out.min() == pytest.approx(0, abs=1e-6)


def test_monotonic_distinct_and_ach_preserved():
    limits = LIMITS
    for channel in range(3):
        d = np.linspace(0, limits[channel]*3, 10001)
        rgb = np.ones((len(d), 3))
        rgb[:, channel] -= d
        out = compress(rgb, THRESHOLD, limits)
        assert np.all(np.diff(1-out[:, channel]) > 0)
        np.testing.assert_array_equal(out.max(axis=-1), rgb.max(axis=-1))


def test_neutrals_and_empty():
    rgb = np.repeat(np.array([-3., 0., .18, 1., 100.])[:, None], 3, axis=1)
    np.testing.assert_array_equal(compress(rgb), rgb)
    assert compress(np.empty((0, 3))).shape == (0, 3)


def test_spectral_boundary_maps_inside_scene_gamut():
    xyz = cie_1931()
    xyz /= xyz.sum(axis=-1, keepdims=True)
    boundary = np.concatenate([a[None, :] + np.linspace(0, 1, 101)[:, None]*(b-a)
                               for a, b in zip(xyz, np.roll(xyz, -1, axis=0))])
    rgb = boundary @ XYZ_TO_RGB.T
    out = compress(rgb)
    assert out.min() >= -1e-6
    np.testing.assert_array_equal(out.max(axis=-1), rgb.max(axis=-1))


@pytest.mark.parametrize("power,threshold,limit", [
    (0, THRESHOLD, (1.4, 1.2, 1.1)),
    (POWER, (1, .8, .8), (1.4, 1.2, 1.1)),
    (POWER, THRESHOLD, (1, 1.2, 1.1)),
])
def test_invalid_curve_parameters(power, threshold, limit):
    with pytest.raises(ValueError):
        compress([1, 0, 0], threshold, limit, power)


def test_invalid_rgb():
    with pytest.raises(ValueError):
        compress([1, 0])


def test_matrices_share_d65_white():
    np.testing.assert_allclose(XYZ_TO_RGB @ (RGB_TO_XYZ @ np.ones(3)), np.ones(3), atol=1e-14)
