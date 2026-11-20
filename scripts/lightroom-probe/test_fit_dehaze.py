"""python -I -m pytest -q scripts/lightroom-probe/test_fit_dehaze.py: the Dehaze stage's invariants, on synthetic frames."""
import sys
from dataclasses import asdict
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fit_dehaze as fd  # noqa: E402
import presence_charts  # noqa: E402


def hazy(width=640, height=427, airlight=(0.72, 0.74, 0.80)):
    scene = presence_charts.haze_texture(width, height, seed=3)
    t = 1 - 0.8 * (np.arange(width) + 0.5) / width
    return scene * t[None, :, None] + np.array(airlight) * (1 - t)[None, :, None], t


@pytest.fixture(params=["dark-channel", "global-veil"])
def constants(request):
    return fd.Constants(method=request.param, kappa_values=[0, 100], kappa=[0, 0.8], haze_values=[0, 100],
                        haze_share=[0, 0.9], haze_power=[3, 3])


def test_zero_is_the_input_itself(constants):
    scene, _ = hazy()
    fld = fd.Field(scene, constants)
    assert fd.dehaze(scene, 0, fld, constants) is scene


def test_exposure_commutes(constants):
    scene, _ = hazy()
    for value in (100, -60):
        once = fd.dehaze(scene, value, fd.Field(scene, constants), constants)
        doubled = fd.dehaze(2 * scene, value, fd.Field(2 * scene, constants), constants)
        assert np.abs(doubled - 2 * once).max() < 1e-9


def test_a_flat_frame_is_its_own_airlight(constants):
    scene = np.full((300, 450, 3), 0.18)
    fld = fd.Field(scene, constants)
    for value in (100, -100):
        assert np.abs(fd.dehaze(scene, value, fld, constants) - scene).max() < 1e-6


def test_dark_channel_gains_most_where_the_haze_is_thickest():
    c = fd.Constants(kappa_values=[0, 100], kappa=[0, 0.8])
    scene, t = hazy()
    fld = fd.Field(scene, c)
    G = c.gain(fld.transmission(scene, c), 100)
    left, right = np.median(G[:, : scene.shape[1] // 8]), np.median(G[:, -scene.shape[1] // 8:])
    assert left < 1.3 < 2.0 < right


def test_negative_values_pull_toward_the_airlight(constants):
    scene, _ = hazy()
    fld = fd.Field(scene, constants)
    out = fd.dehaze(scene, -100, fld, constants)
    assert np.linalg.norm(out - fld.A, axis=-1).mean() < np.linalg.norm(scene - fld.A, axis=-1).mean()


def test_the_field_is_the_same_from_a_downsampled_frame():
    c = fd.Constants()
    scene, _ = hazy(2048, 1366)
    small = fd.blocks(scene, 2)
    full, half = fd.Field(scene, c), fd.Field(small, c)
    assert np.abs(full.A / half.A - 1).max() < 0.01
    t_full = fd.blocks(full.transmission(scene, c)[..., None], 2)[..., 0]
    t_half = half.transmission(small, c)
    assert np.percentile(np.abs(t_full - t_half), 99) < 0.02


def test_banded_frame_matches_the_whole():
    c = fd.Constants(kappa_values=[0, 100], kappa=[0, 0.8])
    scene, _ = hazy(640, 600)
    fld = fd.Field(scene, c)
    whole = fd.dehaze(scene, 100, fld, c)
    assert np.abs(fd.dehaze_frame(scene, 100, fld, c, tile=128) - whole).max() < 1e-5


def test_laws_are_identity_at_full_transmission():
    for law in ("crossfade", "power", "mirror"):
        c = fd.Constants(negative_law=law)
        assert abs(c.gain(np.array(1.0), -50) - 1) < 1e-12
    for law in ("beer-lambert", "linear-t"):
        c = fd.Constants(positive_law=law)
        assert abs(c.gain(np.array(1.0), 50) - 1) < 1e-12


def test_auto_balance_without_a_cast_is_zero():
    assert np.abs(fd.auto_balance_correction(np.zeros(3))).max() == 0


def test_constants_round_trip():
    c = fd.Constants(omega=0.9, kappa=[0, 0.1, 0.2, 0.3])
    assert fd.Constants(**asdict(c)) == c


def test_negative_values_in_gamma_space_commute_with_exposure():
    c = fd.Constants(negative_space="gamma", haze_values=[0, 100], haze_share=[0, 0.8], haze_power=[2, 2])
    scene, _ = hazy()
    once = fd.dehaze(scene, -70, fd.Field(scene, c), c)
    doubled = fd.dehaze(2 * scene, -70, fd.Field(2 * scene, c), c)
    assert np.abs(doubled - 2 * once).max() < 1e-9
    flat = np.full((200, 300, 3), 0.18)
    assert np.abs(fd.dehaze(flat, -70, fd.Field(flat, c), c) - flat).max() < 1e-6


def fake_spike(folder, usage):
    path = folder / "argent-spike"
    path.write_text(f"#!/bin/sh\ncat <<'USAGE'\n{usage}\nUSAGE\nexit 2\n")
    path.chmod(0o755)
    return path


def test_the_spike_command_stops_until_the_spike_has_the_flag(tmp_path):
    binary = fake_spike(tmp_path, "usage: argent-spike <file.ARW> [options]\n  --auto  develop as the app's Auto")
    with pytest.raises(SystemExit, match="no --dehaze flag yet"):
        fd.command_spike(binary)


def test_a_missing_spike_is_named(tmp_path):
    with pytest.raises(SystemExit, match="no argent-spike at"):
        fd.require_dehaze_flag(tmp_path / "argent-spike")


def test_a_spike_with_the_flag_is_accepted(tmp_path):
    fd.require_dehaze_flag(fake_spike(tmp_path, "  --dehaze V       Dehaze, -100...100 (default: 0)"))


def bars_for(frames):
    return {"stocks": ["s"], "values": [-100, 100], "frames": frames,
            "fidelity": {"s": {"change": {"max": 5.0, "prototypeAuto": 4.0, "prototypeAim": 4.5}}},
            "perFrame": {"s": {f: {"max": 6.0, "prototypeAuto": 5.0, "prototypeAim": 5.2} for f in frames}}}


def test_judge_passes_at_the_bar_and_fails_above_it():
    bars = bars_for(["a", "b"])
    scores = {"s": {"a": {-100: {"change": 4.0}, 100: {"change": 6.0}}, "b": {-100: {"change": 5.0}, 100: {"change": 5.0}}}}
    assert all(r["pass"] for r in fd.judge(bars, scores))
    scores["s"]["a"][100]["change"] = 9.0
    verdicts = {r["bar"]: r["pass"] for r in fd.judge(bars, scores)}
    assert verdicts == {"fidelity, mean change": False, "frame a, change": False, "frame b, change": True}


def test_judge_gives_a_subsets_mean_with_no_verdict_even_over_the_bar():
    bars = bars_for(["a", "b"])
    rows = {r["bar"]: r for r in fd.judge(bars, {"s": {"a": {-100: {"change": 9.0}, 100: {"change": 7.0}}}})}
    assert set(rows) == {"fidelity, mean change", "frame a, change"}
    mean = rows["fidelity, mean change"]
    assert (mean["measured"], mean["frames"], mean["pass"]) == (8.0, 1, None)
    assert rows["frame a, change"]["pass"] is False


def held_entry(auto, aim):
    rows = {}
    for v in fd.HELD_OUT_VALUES:
        rows[f"dark-channel auto {v:+d}"] = {"clip": {"change": auto, "lRms": auto / 2}}
        rows[f"dark-channel aim {v:+d}"] = {"clip": {"change": aim, "lRms": aim / 2}}
    return {"stocks": {s: {"rows": rows} for s in fd.FILM_STOCKS}}


def test_the_bar_takes_the_worse_protocol_with_its_margin():
    held = {"a": held_entry(4.0, 3.0), "b": held_entry(2.0, 6.0)}
    bars = fd.make_bars(held, ["a", "b"], "constants.json")
    for stock in fd.FILM_STOCKS:
        assert bars["fidelity"][stock]["change"]["max"] == round(max(3.0, 4.5) * 1.05, 2)
        assert bars["perFrame"][stock]["a"]["max"] == 4.5
        assert bars["perFrame"][stock]["b"]["max"] == 6.6


def test_the_smooth_law_keeps_the_photo_knots_and_rises_with_the_value():
    c = fd.Constants(kappa_values=[0, 10, 25, 50, 75, 100], kappa=[0, 0.08, 0.19, 0.42, 0.54, 0.79],
                     haze_values=[0, 10, 25, 50, 75, 100], haze_share=[0, 0.05, 0.16, 0.41, 0.41, 0.77],
                     haze_power=[4.4, 4.4, 4.0, 4.0, 7.8, 7.7])
    smooth, _ = fd.smooth_law(c)
    t = np.linspace(0.1, 1.0, 10)
    for v in (-100, -50, 50, 100):
        assert np.abs(smooth.gain(t, v) - c.gain(t, v)).max() < 1e-9
    positive = [smooth.gain(t, v) for v in range(5, 101, 5)]
    negative = [smooth.gain(t, -v) for v in range(5, 101, 5)]
    assert all((b >= a - 1e-12).all() for a, b in zip(positive, positive[1:]))
    assert all((b <= a + 1e-12).all() for a, b in zip(negative, negative[1:]))


def test_the_crossfade_fit_recovers_its_law():
    t = np.linspace(0.2, 1.0, 24)
    s, c, rms = fd.crossfade_fit(t, 1 - 0.5 * (1 - t ** 3))
    assert abs(s - 0.5) < 0.01 and abs(c - 3) < 0.13 and rms < 0.01


def test_registration_finds_the_quarter_turn():
    scene, _ = hazy(96, 64)
    lab = fd.lab_prophoto(np.rot90(scene, 1) @ fd.REC2020_TO_PROPHOTO.T)
    k, corr = fd.registration(scene, lab)
    assert k == 1 and corr > 0.99


def test_a_banded_ratio_is_the_whole_one():
    rng = np.random.default_rng(1)
    scene = rng.uniform(0.01, 1, (300, 200, 3)).astype(np.float32)
    R = rng.uniform(0.5, 2, (10, 7, 3))
    whole = scene * np.stack([fd.sample_at(R[..., i], scene.shape[:2]) for i in range(3)], axis=-1).astype(np.float32)
    assert np.abs(fd.scaled_by(scene, R, tile=64) - whole).max() == 0


def test_a_fresh_run_of_some_frames_keeps_the_others(tmp_path, monkeypatch):
    path = tmp_path / "scores.json"
    path.write_text('{"a": {"old": 1}, "b": {"old": 1}}')
    monkeypatch.setattr(fd, "held_out_case", lambda job, *args, **kwargs: {"new": job})
    out = fd.run_frames(path, ["b"], {}, [100], fresh=True, log=lambda *_: None)
    assert out["a"] == {"old": 1} and out["b"]["new"] == "b"
    assert fd.json.loads(path.read_text())["a"] == {"old": 1}
