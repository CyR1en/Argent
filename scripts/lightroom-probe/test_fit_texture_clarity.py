"""python -I -m pytest -q scripts/lightroom-probe/test_fit_texture_clarity.py: the candidates' identities and laws."""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fit_texture_clarity as F  # noqa: E402

rng = np.random.default_rng(7)
Y = (0.18 * np.exp2(rng.normal(0, 1, (96, 144)))).astype(np.float32)
g = np.log2(Y)


def test_zero_returns_the_input_exactly():
    for c in F.CANDIDATES.values():
        for key in ("positive", "negative"):
            D, _ = F.make_detail(c[key], Y.astype(np.float64), g)
            delta = F.strength(c[key], 0) * D
            assert np.array_equal(Y * np.exp2(delta), Y), c["name"]


def test_a_flat_frame_has_no_detail():
    flat = np.full((64, 96), 0.18, np.float32)
    for c in F.CANDIDATES.values():
        D, base = F.make_detail(c["positive"], flat.astype(np.float64), np.log2(flat))
        assert np.abs(D).max() < 1e-5, c["name"]


def test_the_pyramid_collapses_to_its_input():
    levels, residual = F.pyramid(g, 4)
    assert np.abs(F.collapse(levels, residual) - g).max() < 1e-4


def test_strength_is_zero_at_zero_and_follows_the_law():
    s = F.side("guided", law=(0.2, 0.4, 0.6, 0.8), field=1024, radius=0.08, epsilon=1.0)
    assert F.strength(s, 0) == 0 and F.strength(s, 100) == 0.8 and F.strength(s, -50) == 0.4


def test_exposure_leaves_the_guided_detail_unchanged():
    s = F.CANDIDATES["clarity-guided"]["positive"]
    D0, _ = F.make_detail(s, Y.astype(np.float64), g)
    D1, _ = F.make_detail(s, (2 * Y).astype(np.float64), g + 1)
    assert np.abs(D1 - D0).max() < 1e-4
