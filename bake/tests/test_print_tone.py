"""The print-tone report against US5300381's FIG. 1 and FIG. 2 and US7372597."""

import numpy as np
import pytest

from argent_bake.negative import MID_GRAY
from argent_bake.print_stage import figure_stage
from argent_bake.print_tone import (FIG1_PRINT, FIG2_PRINT, FIGURE_SCENE, FIGURES, GRAY_SCALE, SCENE,
                                    figure_midtone_slope, print_tone, report_lines)
from tests.conftest import STOCK_NAMES


@pytest.mark.parametrize("name", STOCK_NAMES)
def test_every_stock_reports_its_print_tone(stocks, name):
    tone = print_tone(stocks[name])
    # Every step of the KODAK Paper Gray Scale prints distinct (measure.md section 3.1).
    assert tone.gray_scale.shape == GRAY_SCALE.shape and np.all(np.diff(tone.gray_scale) > 0.04)
    # Mid-gray is the daylight reference, 0.18 of paper white, on every stock.
    assert tone.mid_gray == pytest.approx(0.848, abs=0.005)
    assert 0.0 < tone.flare < 0.02 and np.isfinite(tone.rms) and tone.rms_shifted <= tone.rms
    assert len(report_lines(tone)) == 6


def test_portra_400_reads_as_measure_md_measured_it(stocks):
    # measure.md section 3.2, ENDURA Premier: mid-gray 0.829 with flare, mid-tone 1.74, peak 2.28, rms 0.141 and
    # 0.074 after a shift (on its own 1,336-point digitization), L* gamma 2.02 and 2.19.
    tone = print_tone(stocks["portra400"])
    assert tone.mid_gray_flare == pytest.approx(0.829, abs=0.005)
    assert tone.mid_gradient == pytest.approx(1.74, abs=0.03) and tone.peak_gradient == pytest.approx(2.28, abs=0.05)
    assert tone.rms == pytest.approx(0.141, abs=0.01) and tone.rms_shifted == pytest.approx(0.074, abs=0.01)
    assert tone.max_lstar_gamma == pytest.approx(2.02, abs=0.03) and tone.max_lstar_gamma_paper == pytest.approx(2.19, abs=0.03)


def test_the_figures_are_the_patent_as_digitized():
    # tools/digitize_us5300381.py on the patent's drawing sheets 1 and 2; FIG. 2 against measure.md's 13 points
    # read by eye (0.750 at mid-gray, 1.768 at 1.45, 1.999 at 2.4).
    for curve in (FIG1_PRINT, FIG2_PRINT):
        assert curve.shape == FIGURE_SCENE.shape
    assert np.interp(0.75, FIGURE_SCENE, FIG2_PRINT) == pytest.approx(0.750, abs=0.006)
    assert np.interp(1.45, FIGURE_SCENE, FIG2_PRINT) == pytest.approx(1.768, abs=0.006)
    assert FIG2_PRINT[-1] == pytest.approx(1.999, abs=0.006) and FIG1_PRINT.max() == pytest.approx(2.05, abs=0.01)
    # The amateur system is the harder of the two over the patent's mid-tone range.
    assert figure_midtone_slope("FIG. 2") == pytest.approx(1.45, abs=0.01)
    assert figure_midtone_slope("FIG. 1") == pytest.approx(1.65, abs=0.01)


@pytest.mark.parametrize("figure", ["FIG. 1", "FIG. 2"])
def test_the_digitized_curves_never_fall(figure):
    # A print's density rises with scene density; a reading that falls has followed the dashed gradient curve where it
    # crosses. FIG. 2 read 0.150 then 0.147 at scene 0.0 and 0.05 until 2026-11-23, and the Portras' tone stage turned
    # that into a flat stretch 2.5 to 2.7 stops over mid-gray. The slack is one pixel of the drawing (480 pixels per unit
    # of density, 0.002 D): FIG. 1's last two readings, 2.052 and 2.051 at 2.35 and 2.4, are on its flat shoulder.
    curve = FIGURES[figure]
    falls = np.diff(curve)
    worst = int(np.argmin(falls))
    assert falls[worst] >= -0.002, f"{figure} falls {-falls[worst]:.3f} D after scene density {FIGURE_SCENE[worst]:.2f}"


@pytest.mark.parametrize("name", ["portra160", "portra400", "portra800", "portra160natural"])
def test_the_figure_2_stage_rises_through_the_highlights(stocks, endura, name):
    # Every knot of the stage brighter than mid-gray maps to more paper exposure than the last, on each layer, so no
    # stretch of the highlights prints flat. On the reading corrected 2026-11-23 the four Portras' stages have no flat
    # knot above mid-gray; before it they had seven, 2.51 to 2.71 stops over. The stage's flat knots that remain are
    # in the deep shadows, 4.4 stops under mid-gray and darker, where the target is held at the paper's black.
    stage = figure_stage(stocks[name], endura)
    stops = (-np.log10(MID_GRAY) - SCENE) / np.log10(2.0)
    rises = np.diff(stage.knots_out, axis=0)
    flat = stops[:-1][np.any(rises <= 1e-9, axis=1) & (stops[:-1] > 0)]
    assert flat.size == 0, f"{name}: the stage is flat at {np.round(flat, 2)} stops over mid-gray"
