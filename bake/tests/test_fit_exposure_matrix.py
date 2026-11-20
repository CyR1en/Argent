"""The exposure matrix fit's options (tools/fit_exposure_matrix.py), on synthetic data: package G's row-length cap and
ridge keep rows summing to one, and do what they say (docs/research/film-sim/matrix.md section 2)."""
import importlib.util
from pathlib import Path

import numpy as np
import pytest

_spec = importlib.util.spec_from_file_location("fit_exposure_matrix",
                                               Path(__file__).resolve().parents[1] / "tools" / "fit_exposure_matrix.py")
F = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(F)

TRUE = np.array([[1.8, -1.0, 0.2], [-0.05, 0.9, 0.15], [0.0, 0.0, 1.0]])


def data():
    rng = np.random.default_rng(0)
    rgb = np.exp(rng.normal(0, 0.4, size=(300, 3)))
    exposure = np.maximum(rgb @ TRUE.T, 1e-3)
    keep = np.all(rgb @ TRUE.T > 1e-3, axis=1)
    return rgb[keep], exposure[keep], np.full(keep.sum(), 1.0 / keep.sum())


def test_the_plain_fit_recovers_a_rows_sum_to_one_matrix():
    rgb, exposure, w = data()
    m = F.fit_rows(rgb, exposure, w, np.eye(3))
    assert m == pytest.approx(TRUE, abs=1e-6)


def test_a_row_cap_bounds_each_row_and_keeps_rows_summing_to_one():
    rgb, exposure, w = data()
    m = F.fit_rows(rgb, exposure, w, np.eye(3), cap=1.5)
    assert m.sum(axis=1) == pytest.approx(np.ones(3), abs=1e-9)
    lengths = np.linalg.norm(m, axis=1)
    assert lengths[0] == pytest.approx(1.5, abs=1e-6)
    # rows already under the cap are the plain fit's
    assert m[1:] == pytest.approx(TRUE[1:], abs=1e-6)


def test_a_strong_ridge_pulls_toward_its_reference():
    rgb, exposure, w = data()
    ref = np.full((3, 3), 1.0 / 3.0) + np.eye(3) * 0.1 - 0.1 / 3
    weak = F.fit_rows(rgb, exposure, w, np.eye(3), ridge=1e-6, toward=ref)
    strong = F.fit_rows(rgb, exposure, w, np.eye(3), ridge=1e3, toward=ref)
    assert np.abs(weak - TRUE).max() < 1e-3
    assert np.abs(strong - ref).max() < 0.01
    assert strong.sum(axis=1) == pytest.approx(np.ones(3), abs=1e-9)
