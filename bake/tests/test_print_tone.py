"""The print-tone report against US5300381's FIG. 1 and FIG. 2 and US7372597."""

import numpy as np
import pytest

from argent_bake.print_tone import (FIG1_PRINT, FIG2_PRINT, FIGURE_SCENE, GRAY_SCALE, figure_midtone_slope,
                                    print_tone, report_lines)
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
        assert np.all(np.diff(curve[FIGURE_SCENE >= 0.1]) > -0.002)  # rising, to the reading
    assert np.interp(0.75, FIGURE_SCENE, FIG2_PRINT) == pytest.approx(0.750, abs=0.006)
    assert np.interp(1.45, FIGURE_SCENE, FIG2_PRINT) == pytest.approx(1.768, abs=0.006)
    assert FIG2_PRINT[-1] == pytest.approx(1.999, abs=0.006) and FIG1_PRINT.max() == pytest.approx(2.05, abs=0.01)
    # The amateur system is the harder of the two over the patent's mid-tone range.
    assert figure_midtone_slope("FIG. 2") == pytest.approx(1.45, abs=0.01)
    assert figure_midtone_slope("FIG. 1") == pytest.approx(1.65, abs=0.01)
