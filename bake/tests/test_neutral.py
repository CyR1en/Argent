import hashlib
import json
import math

import numpy as np
import pytest

from argent_bake import neutral
from argent_bake.__main__ import main
from argent_bake.cube import read_binary, read_cube
from argent_bake.negative import FILM_LOG_ENCODING, MID_GRAY
from tests.test_bake import lut_array, trilinear


def _lstar(y):
    y = np.maximum(np.asarray(y, dtype=np.float64), 0.0)
    return np.where(y > (6 / 29) ** 3, 116.0 * np.cbrt(y) - 16.0, (29 / 3) ** 3 * y)


@pytest.fixture(scope="module")
def baked_neutral(tmp_path_factory):
    out = tmp_path_factory.mktemp("neutral")
    result = neutral.bake_neutral(out, size=65)
    return out, result


def test_tone_curve_anchors_mid_gray_black_and_white():
    assert float(neutral.tone_curve(0.0)) == 0.0
    assert float(neutral.tone_curve(MID_GRAY)) == pytest.approx(MID_GRAY, abs=1e-9)
    assert float(neutral.tone_curve(MID_GRAY * 2.0 ** -8)) < 0.002
    assert float(neutral.tone_curve(MID_GRAY * 2.0 ** 8)) > 0.999
    assert float(neutral.tone_curve(1e6)) <= 1.0


def test_tone_curve_is_strictly_monotonic():
    stops = np.linspace(-8.0, 8.0, 200)
    y_out = neutral.tone_curve(MID_GRAY * 2.0 ** stops)
    assert np.all(np.diff(y_out) > 0)


def test_tone_curve_has_moderate_contrast_open_shadows_and_soft_highlights():
    def at_stop(ev):
        return float(neutral.tone_curve(MID_GRAY * 2.0 ** ev))

    # Moderate midtone contrast: steeper than linear (15.3 L*/EV), gentler than Portra 400 (22.9 L*/EV).
    mid_slope = (float(_lstar(at_stop(1.0))) - float(_lstar(at_stop(-1.0)))) / 2.0
    assert 16.5 < mid_slope < 20.0

    # Open shadows: -2 EV and -3 EV stay well above Portra 400 (L* 13.8 and 7.0) with strong separation.
    l_minus2 = float(_lstar(at_stop(-2.0)))
    l_minus3 = float(_lstar(at_stop(-3.0)))
    assert l_minus2 > 18.0
    assert l_minus3 > 10.0
    assert l_minus2 - l_minus3 > 7.0

    # Soft highlight roll-off: headroom at +2 EV, smooth compression through +3 and +4 EV with no hard clip.
    y_plus2, y_plus3, y_plus4 = at_stop(2.0), at_stop(3.0), at_stop(4.0)
    assert 0.65 < y_plus2 < 0.76
    assert 0.85 < y_plus3 < 0.94
    assert y_plus3 < y_plus4 < 0.995


def test_develop_preserves_exact_camera_colour_for_in_gamut_colours():
    # Neutral grays stay strictly equal across channels.
    grays = np.repeat((MID_GRAY * 2.0 ** np.linspace(-6, 6, 25))[:, None], 3, axis=1)
    out_grays = neutral.develop(grays)
    assert np.max(np.abs(out_grays[:, 0] - out_grays[:, 1])) == 0.0
    assert np.max(np.abs(out_grays[:, 1] - out_grays[:, 2])) == 0.0

    # In-gamut saturated colours keep their exact RGB chromaticity ratios.
    colours = np.array([
        [0.40, 0.22, 0.16],  # skin
        [0.10, 0.25, 0.55],  # sky blue
        [0.50, 0.12, 0.08],  # red
        [0.12, 0.35, 0.10],  # foliage green
        [0.30, 0.26, 0.08],  # warm yellow
    ])
    developed = neutral.develop(colours)
    for src, dst in zip(colours, developed):
        ratio = dst / src
        assert ratio == pytest.approx(np.full(3, ratio[0]), rel=1e-12, abs=1e-12)


def test_develop_rolls_off_bright_saturated_highlights_without_hue_shift():
    bright = np.array([
        [1.80, 0.70, 0.15],  # bright sunset orange
        [0.20, 0.60, 2.40],  # bright blue sky
        [3.00, 0.40, 0.30],  # bright red light
    ])
    developed = neutral.develop(bright)
    assert np.all(developed >= 0.0) and np.all(developed <= 1.0)
    y_in = bright @ neutral.REC2020_LUMA
    y_expected = neutral.tone_curve(y_in)
    y_actual = developed @ neutral.REC2020_LUMA
    assert y_actual == pytest.approx(y_expected, abs=1e-9)

    # Deviation from neutral (Y, Y, Y) stays collinear with the input chroma direction (zero hue skew).
    for src, dst, yi, yo in zip(bright, developed, y_in, y_actual):
        d_in = src - yi
        d_out = dst - yo
        cosine = float(np.dot(d_in, d_out) / (np.linalg.norm(d_in) * np.linalg.norm(d_out)))
        assert cosine == pytest.approx(1.0, abs=1e-12)


def test_baked_neutral_manifest_and_luts(baked_neutral):
    out, result = baked_neutral
    assert sorted(p.name for p in out.iterdir()) == [
        "negative.cube", "negative.lut3d", "print.cube", "print.lut3d", "stock.json"
    ]
    manifest = json.loads((out / "stock.json").read_text())
    assert manifest["schema"] == 2
    assert manifest["id"] == "argent-neutral"
    assert manifest["displayName"] == "Neutral"
    assert manifest["modelledFilm"] is None
    assert manifest["status"] == "digital"
    assert manifest["boxSpeed"] == 100.0
    assert manifest["grain"] is None
    assert manifest["halation"] is None
    assert manifest["negative"]["size"] == 65 and manifest["print"]["size"] == 65
    assert manifest["negative"]["logEncoding"] == {
        "stopsBelowMidGray": 8.0, "stopsAboveMidGray": 8.0, "midGray": 0.18,
    }
    assert manifest["print"]["exposurePerUnit"] == [1.0, 1.0, 1.0]
    assert manifest["densityRange"] == pytest.approx(FILM_LOG_ENCODING.range * math.log10(2.0), abs=1e-5)

    for stem in ("negative", "print"):
        size, rows = read_cube(str(out / f"{stem}.cube"))
        binary_size, binary_rows = read_binary(str(out / f"{stem}.lut3d"))
        assert binary_size == size == 65 and len(binary_rows) == len(rows)
        assert np.abs(np.array(binary_rows) - np.array(rows)).max() < 1e-6


def test_baked_neutral_mid_gray_and_exposure_offset(baked_neutral):
    out, result = baked_neutral
    negative = lut_array(out / "negative.cube", 65)
    print_lut = lut_array(out / "print.cube", 65)

    mid_u = np.full((1, 3), FILM_LOG_ENCODING.encode(MID_GRAY))
    dyes = trilinear(negative, mid_u)
    printed = trilinear(print_lut, dyes)[0]
    assert printed == pytest.approx(np.full(3, MID_GRAY), abs=1e-5)

    # +1 stop of print exposure shifts dye input by log10(2) / (exposurePerUnit * densityRange)
    # and must match developing 2 * MID_GRAY directly.
    one_stop_offset = math.log10(2.0) / (result.exposure_per_unit * result.density_range)
    shifted = trilinear(print_lut, np.clip(dyes + one_stop_offset, 0.0, 1.0))[0]
    expected = neutral.develop(np.full(3, MID_GRAY * 2.0))
    assert shifted == pytest.approx(expected, abs=1e-4)


def test_bake_neutral_cli_and_determinism(tmp_path, capsys):
    a, b = tmp_path / "a", tmp_path / "b"
    assert main(["bake", "--neutral", "--size", "9", "--out", str(a)]) == 0
    assert "wrote" in capsys.readouterr().out
    assert main(["bake", "--neutral", "--size", "9", "--out", str(b)]) == 0
    digest = lambda d: {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(d.iterdir())}
    assert digest(a) == digest(b)
