"""python -I -m pytest -q scripts/lightroom-probe/test_fit_clarity_round2.py: the instruments of Clarity's round 2."""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fit_clarity_round2 as R  # noqa: E402

rng = np.random.default_rng(11)


def test_the_local_laplacian_filter_leaves_a_flat_frame_alone():
    flat = np.full((64, 96), -2.0, np.float32)
    for kind, sigma, alpha in R.LLF_SETTINGS[::4]:
        E, _ = R.llf_levels(flat, kind, sigma, 4, alpha or 0.5)
        assert max(float(np.abs(e).max()) for e in E) < 1e-6, kind


def test_the_local_laplacian_filter_ignores_exposure():
    g = rng.normal(-3, 1, (96, 128)).astype(np.float32)
    for kind in ("gauss", "cauchy"):
        E0, _ = R.llf_levels(g, kind, 0.3, 4)
        E1, _ = R.llf_levels(g + np.float32(1.5), kind, 0.3, 4)
        assert all(np.abs(a - b).max() < 1e-4 for a, b in zip(E0, E1)), kind


def test_remaps_are_odd_and_zero_at_zero():
    d = np.linspace(-3, 3, 61).astype(np.float32)
    for kind in ("gauss", "cauchy", "power"):
        f = R.remap_detail(kind, d, 0.5)
        assert np.allclose(f, -f[::-1], atol=1e-6) and abs(float(f[30])) < 1e-9, kind


def test_hats_are_a_partition_of_unity():
    x = rng.uniform(-14, 2, 1000)
    assert np.allclose(R.hats(x, R.GLOBAL_KNOTS).sum(axis=0), 1, atol=1e-6)


def test_nnls_keeps_coefficients_positive_and_matches_least_squares_when_it_can():
    M = rng.normal(size=(80, 6))
    k = R.nnls(M, M @ np.array([1.0, -2.0, 0.5, 0.0, 3.0, -1.0]))
    assert k.min() >= 0
    truth = np.array([1.0, 2.0, 0.5, 0.1, 3.0, 1.0])
    assert np.allclose(R.nnls(M, M @ truth), truth, atol=1e-8)


def _ceiling_from(frames):
    c = R.Ceiling.__new__(R.Ceiling)
    c.g = {}
    for j, (X, y) in frames.items():
        c.g[j] = {"XtX": X.T @ X, "n": len(y), "Xty clarity+100": X.T @ y, "yty clarity+100": float(y @ y),
                  "sy clarity+100": float(y.sum())}
    c.names = np.array(["1", "a", "g 0", "g 1"])
    c.groups = np.array(["intercept", "x", "global", "global"])
    c.one, c.curve = 0, np.array([False, False, True, True])
    return c


def test_r2_from_gram_matrices_matches_the_direct_computation():
    frames = {}
    for j in ("f", "h"):
        n = 400
        x, t = rng.normal(size=n), rng.uniform(0, 1, n)
        X = np.stack([np.ones(n), x, t, 1 - t], axis=1)
        frames[j] = (X, 0.7 * x + 0.3 * t + rng.normal(0, 0.1, n) + (0.5 if j == "h" else 0.0))
    c = _ceiling_from(frames)
    mask = np.array([True, True, False, False])
    beta = c.fit(["f"], mask, "clarity+100", 0.0)
    X, y = frames["h"]
    p = X[:, mask] @ beta
    assert abs(c.r2("h", mask, "clarity+100", beta) - (1 - np.sum((y - p) ** 2) / np.sum((y - y.mean()) ** 2))) < 1e-9
    A = np.stack([p, np.ones_like(p)], axis=1)
    resid = y - A @ np.linalg.lstsq(A, y, rcond=None)[0]
    direct = 1 - np.sum(resid ** 2) / np.sum((y - y.mean()) ** 2)
    assert abs(c.r2("h", mask, "clarity+100", beta, ("scale", "intercept")) - direct) < 1e-6


# MARK: The spike scorer under the explicit aim

def aim_runs(slider, value, metric, score, parity=0.1):
    return [{"slider": slider, "job": j, "stock": s, "value": value, "protocol": R.AIM, metric: score,
             f"prototype_{metric}": score - 0.2, "prototype_r2": 0.5, "floor": 1.0, "parity": parity}
            for j, s in sorted(R.bar_runs(slider, value))]


def test_a_bar_set_under_auto_refuses_runs_made_under_the_aim():
    old = {"clarity-guided +100": {"metric": "rmse", "bar": 5.8, "held_out": 5.5, "runs": 54}}
    with pytest.raises(SystemExit, match="set under --auto"):
        R.judge_spike(aim_runs("clarity", 100, "rmse", 5.0), old)


def test_parity_is_judged_against_its_limit_only_on_all_its_runs():
    bars = {"texture-guided-band -50": {"protocol": R.AIM, "metric": "crop_rmse", "bar": 0.4, "held_out": 0.38,
                                        "runs": 14, "parity": {"max": 0.12}}}
    runs = aim_runs("texture", -50, "crop_rmse", 0.39, parity=0.11)
    bar, parity = R.judge_spike(runs, bars)
    assert bar["pass"] is True and parity["pass"] is True and parity["max"] == 0.12 and parity["runs"] == 14
    runs[0]["parity"] = 0.11 + 14 * 0.02
    assert R.judge_spike(runs, bars)[1]["pass"] is False
    assert R.judge_spike(runs[1:], bars)[1]["pass"] is None


def test_the_parity_limit_is_the_mean_and_a_tenth_never_over_the_cap():
    assert R.parity_limit("clarity", 100, 0.2) == 0.22
    assert R.parity_limit("clarity", 100, 0.29) == 0.30
    assert R.parity_limit("clarity", 100, 0.31) is None
    assert R.parity_limit("clarity", 50, 0.15) == 0.165
    assert R.parity_limit("texture", -100, 0.19) == 0.20
    assert R.parity_limit("texture", -100, 0.21) is None


def test_the_bars_are_the_prototypes_held_out_means_and_a_twentieth(tmp_path):
    binary = tmp_path / "argent-spike"
    binary.write_bytes(b"build")
    runs = []
    for slider, metric in (("clarity", "rmse"), ("texture", "crop_rmse")):
        for v in R.VALUES:
            runs += aim_runs(slider, v, metric, 1.0 + abs(v) / 100)
    runs[0]["prototype_rmse"] += 54 * 0.1
    made = R.make_bars(runs, binary)
    first = made["bars"]["clarity-guided -100"]
    assert first["held_out"] == round(1.8 + 0.1, 3) and first["bar"] == round(1.9 * 1.05, 2)
    assert first["protocol"] == R.AIM and first["parity"]["max"] == 0.11
    assert made["replaced"]["bars"] == json.loads((R.OUT / "rule.json").read_text())["bars"]
    with pytest.raises(SystemExit, match="a bar needs all"):
        R.make_bars(runs[1:], binary)


def verdict_rows(clarity_aim, clarity_auto, transfer=0.1, texture_aim=0.05):
    return [{"slider": s, "job": "j", "stock": "s", "value": v, "auto": clarity_auto if s == "clarity" else 0.3,
             "aim": clarity_aim if s == "clarity" else texture_aim, "aim neutral": 0.01, "auto neutral": 0.2,
             "transfer": transfer} for s in R.SPIKE_CANDIDATES for v in R.VALUES]


def test_the_verdict_follows_the_preregistered_rule():
    assert R.protocol_verdict(verdict_rows(0.14, 1.0))[0] == "confirmed"
    assert R.protocol_verdict(verdict_rows(0.2, 1.0))[0] == "partly confirmed"
    assert R.protocol_verdict(verdict_rows(0.31, 1.0))[0] == "refuted"
    assert R.protocol_verdict(verdict_rows(0.14, 0.27))[0] == "refuted"
