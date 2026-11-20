"""python -I -m pytest -q scripts/lightroom-probe/test_fit_colour.py: the colour fit's candidates and helpers."""
import os
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fit_colour as F  # noqa: E402

RNG = np.random.default_rng(7)
COLOURS = RNG.uniform(0.002, 1.5, (2000, 3))
GREYS = np.repeat(RNG.uniform(0.002, 1.5, (50, 1)), 3, axis=1)
VIB = {"pos": dict(F.VIB_START["pos"]), "neg": dict(F.VIB_START["neg"]), "sref": 0.6, "sknee": 0.8}


@pytest.mark.parametrize("space", ["prophoto", "rec2020"])
def test_zero_returns_the_input_itself(space):
    weights = F.LR_LUMA[space]
    assert F.sat_lightroom(COLOURS, 0.0, weights) is COLOURS
    assert F.sat_luma_knee(COLOURS, 0.0, weights) is COLOURS
    assert F.sat_oklab_knee(COLOURS, 0.0, space) is COLOURS
    for fn in F.VIB_MODELS.values():
        assert fn(COLOURS, 0.0, VIB, space) is COLOURS


def test_saturation_minus_100_is_the_grey_of_lightroom_luminance():
    grey = F.sat_lightroom(COLOURS, -1.0, F.LR_LUMA["prophoto"])
    assert np.ptp(grey, axis=1).max() < 1e-12
    np.testing.assert_allclose(grey[:, 0], COLOURS @ F.LR_LUMA["prophoto"], rtol=1e-12)


def test_the_blend_is_the_same_colour_in_either_space():
    rec = RNG.uniform(0.01, 1.0, (500, 3))
    in_rec = F.luma_blend(rec, 1.7, F.LR_LUMA["rec2020"])
    in_pro = F.luma_blend(rec @ F.REC2020_TO_PROPHOTO.T, 1.7, F.LR_LUMA["prophoto"]) @ F.PROPHOTO_TO_REC2020.T
    # The two matrices take white to white only to 2e-4 (the published primaries' rounding), so the blends agree to that.
    np.testing.assert_allclose(in_rec, in_pro, atol=3e-4)


def test_saturation_keeps_luminance_until_a_channel_clips():
    out = F.luma_blend(COLOURS, 1.5, F.LR_LUMA["prophoto"])
    np.testing.assert_allclose(out @ F.LR_LUMA["prophoto"], COLOURS @ F.LR_LUMA["prophoto"], rtol=1e-12)


def test_knee_is_continuous_monotone_and_stays_inside():
    x = np.linspace(0, 1, 2001)
    for k in (1.25, 1.5, 2.0, 3.0):
        y = F.knee(x, k, 0.7)
        assert np.all(np.diff(y) > 0)
        assert y[-1] == pytest.approx(1.0)
        assert y.max() <= 1.0 + 1e-12
        x0 = 0.7 / k
        below = x <= x0
        np.testing.assert_allclose(y[below], k * x[below])
    np.testing.assert_allclose(F.knee(x, 0.6, 0.7), 0.6 * x)


def test_the_knee_keeps_every_channel_non_negative():
    out = F.sat_luma_knee(COLOURS, 1.0, F.LR_LUMA["prophoto"], 0.7)
    assert out.min() >= -1e-12
    ok = F.sat_oklab_knee(COLOURS, 1.0, "prophoto", 0.7)
    assert ok.min() >= -1e-9


@pytest.mark.parametrize("model", ["hsv", "luma", "oklab"])
@pytest.mark.parametrize("s", [-1.0, -0.5, 0.5, 1.0])
def test_vibrance_leaves_greys_alone(model, s):
    out = F.VIB_MODELS[model](GREYS, s, VIB)
    assert np.ptp(out, axis=1).max() < 1e-9
    if model != "hsv":
        np.testing.assert_allclose(out, GREYS, rtol=1e-9)


@pytest.mark.parametrize("s", [-1.0, -0.25, 0.5, 1.0])
def test_hsv_vibrance_holds_each_channels_share(s):
    out = F.vib_hsv(COLOURS, s, VIB)
    share = lambda c: (np.median(c, 1) - c.min(1)) / (c.max(1) - c.min(1))
    moved = np.ptp(out, axis=1) > 1e-6
    np.testing.assert_allclose(share(out)[moved], share(COLOURS)[moved], atol=1e-9)
    np.testing.assert_array_equal(np.argsort(out[moved], 1), np.argsort(COLOURS[moved], 1))


def test_vibrance_minus_100_leaves_c_x_to_the_q_of_saturation():
    S = np.linspace(0.05, 0.95, 19)
    g = F.vib_gain(S, np.zeros_like(S), np.zeros_like(S), -1.0, VIB)
    np.testing.assert_allclose(g, VIB["neg"]["c"] * S ** VIB["neg"]["q"])


def test_rgbtone_holds_the_middle_channels_share():
    out = F.rgbtone(COLOURS, lambda v: v ** 0.5)
    share = lambda c: (np.median(c, 1) - c.min(1)) / (c.max(1) - c.min(1))
    np.testing.assert_allclose(share(out), share(COLOURS), atol=1e-12)
    np.testing.assert_allclose(out.max(1), COLOURS.max(1) ** 0.5)


def test_tone_inverse_round_trips():
    tone = F.Tone(np.geomspace(1e-4, 1, 30), np.geomspace(1e-4, 1, 30) ** 0.6)
    v = np.geomspace(1e-5, 2, 200)
    np.testing.assert_allclose(tone.inverse(tone(v)), v, rtol=1e-9)


def test_change_errors_are_zero_for_the_same_change():
    lab0 = F.lab_prophoto(COLOURS)
    lab1 = F.lab_prophoto(F.luma_blend(COLOURS, 1.4, F.LR_LUMA["prophoto"]).clip(0))
    e = F.change_errors(lab0, lab1, lab0, lab1)
    assert e["dE"]["mean"] == 0 and e["hueP95"] == 0 and e["lightnessP95"] == 0
    assert e["chromaRatio%"]["median"] == 0


@pytest.mark.skipif(not (F.DATA / "grid-tif.npz").exists(), reason="needs the patch tables (fit_colour.py tables)")
def test_lightroom_saturation_law_on_the_grid():
    tone = F.Tone()
    gain = F.saturation_gain(tone)["tif"]["before the curve"]
    for v in (-50, -25, 25, 50, 100):
        d = gain[v]["linear deviation |c - Y| / Y"]
        assert d["median"] == pytest.approx(1 + v / 100, abs=0.01)
        assert d["cv"] < 0.03


def _scaled(P, m):
    """F3's mapping written on the constants themselves: the positive amplitude times m, -100's c over m."""
    Q = {"pos": dict(P["pos"]), "neg": dict(P["neg"]), "sref": P["sref"], "sknee": P["sknee"]}
    Q["pos"]["a1"] *= m
    Q["pos"]["a2"] *= m
    Q["neg"]["c"] /= m
    return Q


@pytest.mark.parametrize("s", [-1.0, -0.5, -0.1, 0.1, 0.5, 1.0])
@pytest.mark.parametrize("m", [0.8, 1.4, 2.5])
def test_vibrance_strength_is_f3s_scaled_constants(s, m):
    np.testing.assert_allclose(F.vib_hsv(COLOURS, s, VIB, "rec2020", m=m),
                               F.vib_hsv(COLOURS, s, _scaled(VIB, m), "rec2020"), rtol=1e-10, atol=1e-12)


def test_vibrance_at_several_strengths_equals_one_strength_at_a_time():
    ms = (1.0, 1.5, 2.2)
    for s in (-0.75, 0.6):
        many = F.vib_hsv_strengths(COLOURS, s, VIB, ms, "rec2020")
        for m, out in zip(ms, many):
            np.testing.assert_array_equal(out, F.vib_hsv(COLOURS, s, VIB, "rec2020", m=m))


def test_a_stronger_vibrance_moves_saturation_further_on_both_sides():
    S = lambda c: (c.max(1) - c.min(1)) / c.max(1)
    base = S(COLOURS @ F.REC2020_TO_PROPHOTO.T)
    for s in (-0.5, 0.5):
        weak, strong = (S(F.vib_hsv(COLOURS, s, VIB, "rec2020", m=m) @ F.REC2020_TO_PROPHOTO.T) for m in (1.0, 2.0))
        moved = np.abs(strong - weak) > 1e-9
        assert moved.mean() > 0.5
        assert np.all(np.abs(strong - base)[moved] >= np.abs(weak - base)[moved] - 1e-12)


def test_the_clip_rule_leaves_out_exactly_the_masked_entries_and_counts_them():
    lab0 = F.lab_prophoto(COLOURS)
    ref = F.lab_prophoto(F.luma_blend(COLOURS, 1.5, F.LR_LUMA["prophoto"]).clip(0))
    keep = RNG.uniform(size=len(COLOURS)) > 0.6
    wild = ref.copy()
    wild[~keep, 1:] *= 5
    every = F.change_errors(lab0, ref, lab0, wild)
    kept = F.change_errors(lab0, ref, lab0, wild, keep=keep)
    assert every["chromaRatio%"]["median"] > 50
    assert kept["chromaRatio%"]["median"] == 0 and kept["hueP95"] == 0
    chroma = (F.lch(lab0)[1] > 5)
    assert kept["clippedLeftOut"] == np.count_nonzero(chroma & ~keep)
    assert kept["chromaCount"] == np.count_nonzero(chroma & keep)
    assert kept["dE"] == every["dE"] and kept["lightnessP95"] == every["lightnessP95"]
    assert F.change_errors(lab0, ref, lab0, wild, keep=np.ones(len(COLOURS), bool))["chromaRatio%"] == every["chromaRatio%"]


def test_gamut_counts_see_white_inside_and_wide_colours_outside():
    white = np.ones((4, 3), np.float32)
    for source in ("lightroom", "argent"):
        c = F.gamut_counts(white, source)
        assert c["sRGBOut"] == 0 and c["P3Out"] == 0
        assert F.gamut_counts(1.5 * white, source)["sRGBOver"] == 4
    rec2020_green = np.array([[0.0, 0.5, 0.0]], np.float32)
    c = F.gamut_counts(rec2020_green, "argent")
    assert c["sRGBNeg"] == 1 and c["P3Neg"] == 1
    srgb_red_in_rec2020 = (np.linalg.inv(F.GAMUTS["argent"]["sRGB"]) @ [0.5, 0.0, 0.0]).astype(np.float32)[None]
    c = F.gamut_counts(srgb_red_in_rec2020, "argent")
    assert c["sRGBOut"] == 0 and c["P3Out"] == 0


def test_staged_stats_base_is_f3s_blocks_and_a_zero_stage_is_the_base():
    p = RNG.uniform(0.0, 1.2, (48, 64, 3)).astype(np.float32)
    stats = F.staged_stats(p, [("saturation", 0, "S-A", 1.0), ("vibrance", 50, "V-A", 1.0)], VIB, rows=8, base=True)
    np.testing.assert_array_equal(stats["base"]["xyz"], F.scene_io.print_xyz(F.block4(p)))
    np.testing.assert_array_equal(stats["saturation+0 S-A m1"]["xyz"], stats["base"]["xyz"])
    assert not np.array_equal(stats["vibrance+50 V-A m1"]["xyz"], stats["base"]["xyz"])
    assert stats["base"]["outRec2020"] == pytest.approx(np.mean((p.min(-1) < 0) | (p.max(-1) > 1)))


def test_registration_finds_a_known_shift():
    y = np.exp(RNG.normal(size=(80, 90)))
    xyz = lambda a: {"xyz": np.repeat(a[..., None], 3, -1).astype(np.float32)}
    assert F.registration(xyz(y[:-4, :-4]), xyz(y[:-4, :-4]))["shift"] == [0, 0]
    assert F.registration(xyz(y[2:-2, 1:-3]), xyz(y[:-4, :-4]))["shift"] == [-2, -1]


def test_a_lean_score_has_the_full_scores_clip_rule_numbers():
    p = RNG.uniform(0.01, 1.0, (64, 96, 3)).astype(np.float32)
    stats = F.staged_stats(p, [("vibrance", 100, "V-A", 1.0)], VIB, rows=16, base=True)
    lr0 = {"xyz": stats["base"]["xyz"] * 0.98, "clip": np.zeros(stats["base"]["xyz"].shape[:2], np.uint8)}
    lr1 = {"xyz": F.scene_io.print_xyz(F.block4(F.vib_hsv(p.astype(np.float64), 0.8, VIB, "rec2020").astype(np.float32))),
           "clip": lr0["clip"].copy()}
    lr1["clip"][:3] = 2
    full = F.score_change(lr0, lr1, stats["base"], stats["vibrance+100 V-A m1"])
    lean = F.score_change(lr0, lr1, stats["base"], stats["vibrance+100 V-A m1"], lean=True)
    assert lean["clip"] == full["clip"]
    assert full["clip"]["clippedLeftOut"] > 0 and full["all"]["clippedLeftOut"] == 0


def test_zero_crossing_interpolates_in_log_strength_and_says_when_the_grid_misses():
    ms = (1.0, 2.0, 4.0)
    assert F.zero_crossing(ms, [10.0, -10.0, -30.0]) == pytest.approx(2 ** 0.5)
    assert F.zero_crossing(ms, [10.0, 5.0, 1.0]) is None
    assert F.zero_crossing(ms, [0.0, -1.0, -2.0]) == pytest.approx(1.0)
    assert F.zero_crossing(ms, [-10.0, 10.0, 30.0]) == pytest.approx(2 ** 0.5)


def test_grid_minimum_finds_the_bottom_of_a_parabola_in_log_strength():
    ms = (1.0, 1.25, 1.5, 1.75, 2.0, 2.5)
    ys = [(np.log(m) - np.log(1.6)) ** 2 for m in ms]
    assert F.grid_minimum(ms, ys) == pytest.approx(1.6, rel=1e-9)
    assert F.grid_minimum(ms, list(range(6))) == 1.0


def test_judge_passes_at_or_under_a_bar_and_fails_over_it_or_when_a_score_is_missing():
    bars = {"saturation": {"kodak-portra-400": {"100": {"ratio%": {"bar": 20.0}, "hueP95": {"bar": 10.0}, "LP95": {"bar": 1.0}}}}}
    scores = {"saturation": {"kodak-portra-400": {"100": {"ratio%": 20.0, "hueP95": 10.5}}}}
    verdict = {metric: ok for _, _, _, metric, _, _, ok in F.judge(scores, bars)}
    assert verdict == {"ratio%": True, "hueP95": False, "LP95": False}


def test_the_build_scorer_stops_before_rendering_when_the_spike_lacks_the_flags(tmp_path):
    calls = tmp_path / "calls"
    fake = tmp_path / "argent-spike"
    fake.write_text(f"#!/bin/sh\necho \"$*\" >> '{calls}'\necho '  --dehaze V       Presence Dehaze'\n")
    fake.chmod(0o755)
    assert F.spike_flags(fake) == set()
    with pytest.raises(SystemExit, match="has no --saturation flag.*Nothing was rendered"):
        F.spike_bars_step(["fit_colour.py", "spike-bars", "--binary", str(fake), "--slider", "saturation"])
    assert set(calls.read_text().splitlines()) == {"--help"}


def test_the_build_scorer_sees_flags_a_binary_lists(tmp_path):
    fake = tmp_path / "argent-spike"
    fake.write_text("#!/bin/sh\necho '  --saturation V   Presence Saturation'\necho '  --vibrance V     Presence Vibrance'\n")
    fake.chmod(0o755)
    assert F.spike_flags(fake) == {"saturation", "vibrance"}


FAKE_BUILD = '''#!{python} -I
"""A stand-in for a Swift build with --saturation and --vibrance: the real spike, then the Python stage on its print."""
import subprocess, sys
from pathlib import Path
sys.path.insert(0, {kit!r})
import numpy as np
args = sys.argv[1:]
if "--help" in args:
    help = subprocess.run([{spike!r}, "--help"], capture_output=True, text=True).stdout
    print(help + "  --saturation V   stand-in\\n  --vibrance V     stand-in")
    sys.exit(0)
slider = value = None
for name in ("saturation", "vibrance"):
    if "--" + name in args:
        i = args.index("--" + name)
        slider, value = name, int(args[i + 1])
        del args[i:i + 2]
run = subprocess.run([{spike!r}, *args])
if run.returncode or not value:
    sys.exit(run.returncode)
import fit_colour as F
path = args[args.index("--print-out") + 1]
stock = Path(args[args.index("--stock") + 1]).name
v = F.stage_variant(slider, value, stock, F.fitted_strengths())
P = F.vibrance_constants()["hsv"]["constants"]
np.save(path, F.chunked(lambda c: next(iter(F.METHODS[v[2]](c, value / 100, [v[3]], P))), np.load(path)))
'''


@pytest.mark.skipif(os.environ.get("ARGENT_SPIKE_TESTS") != "1", reason="renders through the real spike (set ARGENT_SPIKE_TESTS=1)")
def test_a_build_that_is_the_prototype_reproduces_it_exactly(tmp_path):
    fake = tmp_path / "argent-spike"
    fake.write_text(FAKE_BUILD.format(python=sys.executable, kit=str(Path(F.__file__).parent), spike=str(F.SPIKE)))
    fake.chmod(0o755)
    job, stock = F.HELD_OUT[0], "kodak-portra-400"
    scores, reproduce, identity = F.score_build(fake, list(F.HELD_VALUES), frames=[job], stocks=[stock])
    assert all(identity[s] == [True] for s in F.HELD_VALUES)
    assert all(d["mean"] == 0 and d["p99"] == 0 for s in F.HELD_VALUES for d in reproduce[s])
    kept = F.load_runs([job], [stock])[job][stock]
    strengths = F.fitted_strengths()
    for slider, values in F.HELD_VALUES.items():
        for v in values:
            want = F.metrics(kept[F.variant_key(F.stage_variant(slider, v, stock, strengths))])
            got = scores[slider][stock][str(v)]
            for k in ("ratio%", "hueP95", "LP95"):
                assert got[k] == pytest.approx(want[k], abs=1e-9)


def test_spearman_reads_ranks_not_values():
    assert F.spearman([1, 2, 3, 4], [10, 20, 300, 4000]) == pytest.approx(1.0)
    assert F.spearman([1, 2, 3, 4], [4, 3, 2, 1]) == pytest.approx(-1.0)
