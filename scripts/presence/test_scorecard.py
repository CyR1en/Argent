"""python -I -m pytest -q scripts/presence/test_scorecard.py: the Presence scorecard and the two scorers it added to the
fit scripts. Tests that render through the real spike run only with ARGENT_SPIKE_TESTS=1."""
import json
import os
import re
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scorecard as S  # noqa: E402

R, D = S.R, S.D
spike_tests = pytest.mark.skipif(os.environ.get("ARGENT_SPIKE_TESTS") != "1",
                                 reason="renders through the real spike (set ARGENT_SPIKE_TESTS=1)")

FAKE = '''#!{python} -I
"""A build whose Presence stages are not built: a nonzero Presence value stops it with the piece and its package."""
import sys
from pathlib import Path
import numpy as np
args = sys.argv[1:]
with open({log!r}, "a") as f:
    f.write(" ".join(args) + "\\n")
flags = [(a, args[i + 1]) for i, a in enumerate(args) if a in {flags!r}]
for flag, value in flags:
    if float(value) != 0 and flag not in {built!r}:
        sys.stderr.write(f"error: {{flag[2:]}}'s piece (Thing.make) is not built yet: package Z of docs/presence-plan.md builds it.\\n")
        sys.exit(1)
stock = Path(args[args.index("--stock") + 1]).name
moved = 1.0 if {moves!r} in args else 0.0
np.save(args[args.index("--print-out") + 1], np.full((4, 4, 3), len(stock) + moved, np.float32))
'''


def fake_build(folder, moves="--none", built=()):
    path, log = folder / "argent-spike", folder / "calls.log"
    path.write_text(FAKE.format(python=sys.executable, log=str(log), flags=[f"--{s}" for s in S.SLIDERS], moves=moves,
                                built=[f"--{s}" for s in built]))
    path.chmod(0o755)
    return path, log


def script(folder, text, code):
    path = folder / "argent-spike"
    path.write_text(f"#!/bin/sh\ncat >&2 <<'TEXT'\n{text}\nTEXT\nexit {code}\n")
    path.chmod(0o755)
    return path


def test_the_exit_code_says_pass_fail_or_not_judged():
    row = S.Row("dehaze", "bar", "s", 1.0, 2.0, S.PASS)
    assert S.exit_code([row]) == 0
    for status, code in ((S.FAIL, 1), (S.ERROR, 1), (S.NOT_BUILT, 3), (S.PENDING, 3), (S.SUBSET, 3),
                         (S.NOT_MEASURED, 3)):
        assert S.exit_code([row, S.Row("dehaze", "other", "s", status=status)]) == code
    assert S.exit_code([S.Row("x", "a", "s", status=S.NOT_BUILT), S.Row("x", "b", "s", status=S.FAIL)]) == 1
    assert S.exit_code([row], whole=False) == 3
    assert S.exit_code([row, S.Row("dehaze", "other", "s", status=S.FAIL)], whole=False) == 1


def test_a_stage_not_built_is_named_by_the_builds_own_line(tmp_path):
    line = "Texture's band (PresenceAnalysisBuilder.texture) is not built yet: package B of docs/presence-plan.md builds it."
    assert S.stage(script(tmp_path, f"error: {line}", 1), "texture") == (S.NOT_BUILT, line)


def test_a_build_that_renders_the_flag_has_the_stage(tmp_path):
    assert S.stage(script(tmp_path, "", 0), "texture") == (None, "")


def test_a_render_that_fails_another_way_is_an_error(tmp_path):
    status, note = S.stage(script(tmp_path, "Metal: validation failed", 1), "clarity")
    assert status == S.ERROR and "Metal: validation failed" in note


def test_without_stages_identity_is_judged_and_every_other_bar_is_named_not_built_without_rendering(tmp_path):
    binary, log = fake_build(tmp_path)
    rows, _ = S.run(binary, work=tmp_path / "work", log=lambda *a: None)
    identity = [r for r in rows if r.bar.startswith("identity: ")]
    assert len(identity) == 2 * len(S.SLIDERS) and all(r.status == S.PASS for r in identity)
    rest = [r for r in rows if r not in identity]
    assert all(r.status == S.NOT_BUILT and r.note == f"{r.slider}'s piece (Thing.make) is not built yet: package Z of "
               "docs/presence-plan.md builds it." for r in rest)
    assert {(r.slider, r.bar, r.stock) for r in rest} == {
        (r.slider, r.bar, r.stock) for suite in S.SUITES for s in suite.sliders for r in suite.bars([s])}
    calls = log.read_text().splitlines()
    nonzero = [c for c in calls if any(f"--{s} 50" in c for s in S.SLIDERS)]
    assert len(calls) == 2 * (1 + len(S.SLIDERS)) + len(S.SLIDERS)
    assert len(nonzero) == len(S.SLIDERS) and all("--scale 0.25" in c for c in nonzero)
    assert S.exit_code(rows) == 3


def test_a_flag_at_zero_that_moves_the_print_fails_identity(tmp_path):
    binary, _ = fake_build(tmp_path, moves="--clarity")
    rows, _ = S.run(binary, sliders=("clarity", "dehaze"), work=tmp_path / "work", log=lambda *a: None)
    identity = {(r.slider, r.stock): r for r in rows if r.bar.startswith("identity: ")}
    assert all(identity[("clarity", s)].status == S.FAIL and identity[("clarity", s)].measured == 48 for s in S.STOCKS)
    assert all(identity[("dehaze", s)].status == S.PASS for s in S.STOCKS)
    assert S.exit_code(rows) == 1


def test_one_slider_alone_judges_only_its_own_bars(tmp_path):
    binary, log = fake_build(tmp_path)
    rows, _ = S.run(binary, sliders=("dehaze",), work=tmp_path / "work", log=lambda *a: None)
    assert {r.slider for r in rows} == {"dehaze"}
    assert not any(f"--{s} " in c for c in log.read_text().splitlines() for s in S.SLIDERS if s != "dehaze")


def test_every_limit_in_the_bars_files_is_listed():
    colour = json.loads((S.C.OUT / "bars.json").read_text())
    listed = {(r.slider, r.bar, r.stock, r.limit) for r in S.colour_bars(["saturation", "vibrance"])}
    for slider, stocks in colour["bars"].items():
        for stock, values in stocks.items():
            for v, metrics in values.items():
                for metric, b in metrics.items():
                    assert (slider, S.colour_bar(v, metric), stock, b["bar"]) in listed
    dehaze = json.loads(D.BARS.read_text())
    listed = {(r.bar, r.stock): r.limit for r in S.dehaze_bars(["dehaze"])}
    for stock in dehaze["stocks"]:
        assert all(listed[(f"frame {j}, change", stock)] == b["max"] for j, b in dehaze["perFrame"][stock].items())
        assert all(listed[(f"fidelity, mean {m}", stock)] == b["max"] for m, b in dehaze["fidelity"][stock].items())
        assert all(listed[(f"stability {j} {v:+d}", stock)] == m for j in D.STABILITY_FRAMES
                   for v, m in D.STABILITY_MAX[stock].items())
    bars = R.spike_bars()
    listed = {r.bar: r.limit for r in S.detail_bars(["clarity", "texture"])}
    for key, b in bars.items():
        s = next(s for s, name in R.SPIKE_CANDIDATES.items() if key.startswith(name))
        where = "crop" if s == "texture" else "blocks"
        assert listed[f"{s} {key.split()[1]}, mean {b['metric']}"] == b["bar"]
        assert listed[f"{s} {key.split()[1]}, parity: rms ΔL* over the {where} against the prototype's change"] == \
            b["parity"]["max"]



# MARK: Every bar of the list, measured or not

QUICK = S.SUBSETS["quick"]
FAMILIES = {"dehaze": ("dehaze",), "colour": ("saturation", "vibrance"), "detail": ("clarity", "texture")}


@pytest.fixture
def scorers(monkeypatch):
    """Stand-ins for the three families' renders, so a run needs neither Lightroom's exports nor a real build. Every
    run a scorer is asked for scores 0, inside every bar, and is judged by the fit's own judge. Add to the returned set
    to make a stand-in leave runs out, as a scorer that skips a frame would: ("dehaze", frame), ("colour", stock) or
    ("detail", slider, value)."""
    drop = set()
    monkeypatch.setattr(S.C, "SCRATCH", S.C.SCRATCH)
    monkeypatch.setattr(R, "SCRATCH", R.SCRATCH)

    def dehaze(binary, bars, frames=None, parity=True, log=print):
        frames = [j for j in frames or bars["frames"] if ("dehaze", j) not in drop]
        scores = {s: {j: {v: {"change": 0.0, "lRms": 0.0} for v in bars["values"]} for j in frames}
                  for s in bars["stocks"]}
        p = bars["parity"]
        return D.judge(bars, scores) + [
            {"bar": f"parity {j} {v:+d}", "stock": s, "measured": 0.0, "max": p["meanMax"], "p99": 0.0,
             "p99Max": p["p99Max"], "pass": True} for j in p["frames"] for s in bars["stocks"] for v in p["values"]] + [
            {"bar": f"identity {bars['identity']['frame']} at 0", "stock": bars["stocks"][0], "measured": 0.0,
             "max": 0.0, "pass": True}]

    def stability(binary, bars, frames=D.STABILITY_FRAMES, log=print):
        return [{"bar": f"stability {j} {v:+d}", "stock": s, "measured": 0.0, "max": m, "p99": 0.0, "pass": True}
                for j in frames for s in bars["stocks"] for v, m in D.STABILITY_MAX[s].items()]

    def colour(binary, sliders, frames=S.C.HELD_OUT, stocks=S.C.ALL_STOCKS):
        stocks = [st for st in stocks if ("colour", st) not in drop]
        runs = len(frames) * len(stocks)
        return ({s: {st: {str(v): {m: 0.0 for m in S.METRIC_NAMES} for v in S.C.HELD_VALUES[s]} for st in stocks}
                 for s in sliders},
                {s: [{"mean": 0.0, "p99": 0.0}] * runs * len(S.C.HELD_VALUES[s]) for s in sliders},
                {s: [True] * runs for s in sliders})

    def detail(binary, frames=None, stocks=R.F.SCORE_STOCKS, sliders=tuple(R.SPIKE_CANDIDATES), parity=True, log=print):
        return [{"slider": s, "job": j, "stock": st, "value": v, "protocol": R.AIM, "rmse": 0.0, "crop_rmse": 0.0,
                 "parity": 0.0}
                for s in sliders for v in R.VALUES if ("detail", s, v) not in drop
                for j, st in sorted(R.bar_runs(s, v)) if j in (frames or R.HELD + R.ROUND2_PHOTOS) and st in stocks]

    monkeypatch.setattr(D, "score_spike", dehaze)
    monkeypatch.setattr(D, "stability_rows", stability)
    monkeypatch.setattr(S.C, "score_build", colour)
    monkeypatch.setattr(R, "score_spike", detail)
    return drop


def scorecard(tmp_path, sliders, subset):
    """The scorecard's command on a build with every stage built: its exit code, and its rows from scorecard.json
    less the identity bars it measures itself."""
    binary, _ = fake_build(tmp_path, built=S.SLIDERS)
    out = tmp_path / "out"
    code = S.main(["--binary", str(binary), "--subset", subset, "--out", str(out),
                   *(a for s in sliders for a in ("--slider", s))])
    rows = [S.Row(**r) for r in json.loads((out / "scorecard.json").read_text())["rows"]]
    return code, [r for r in rows if not r.bar.startswith("identity: ")]


def listed(sliders):
    return sorted((r.slider, r.bar, r.stock) for suite in S.SUITES for s in suite.sliders if s in sliders
                  for r in suite.bars([s]))


def quick_status(row):
    """What the quick subset must report for a bar: a verdict on a bar of one frame it renders, a subset's value on a
    bar it renders part of, and not measured on a bar it renders none of."""
    kind, frame = row.bar.split()[0], row.bar.split()[1].rstrip(",")
    one_frame = {"frame": QUICK.dehaze, "parity": QUICK.parity, "stability": QUICK.stability}
    if kind == "identity" or frame in one_frame.get(kind, ()):
        return S.PASS
    if row.slider == "dehaze":
        return S.SUBSET if kind == "fidelity," else S.NOT_MEASURED
    if row.slider in FAMILIES["colour"]:
        return S.SUBSET if row.stock in QUICK.colour_stocks + ["all"] else S.NOT_MEASURED
    # Lightroom rendered the quick frame, p-photo-hazy, at every Clarity and Texture value.
    return S.SUBSET


@pytest.mark.parametrize("family", FAMILIES)
def test_a_quick_run_whose_measured_bars_pass_is_no_verdict_and_names_every_bar_it_did_not_judge(tmp_path, scorers,
                                                                                                  family):
    code, rows = scorecard(tmp_path, FAMILIES[family], "quick")
    assert code == 3
    assert sorted((r.slider, r.bar, r.stock) for r in rows) == listed(FAMILIES[family])
    assert {(r.bar, r.stock): r.status for r in rows} == {(r.bar, r.stock): quick_status(r) for r in rows}
    assert all((r.measured is None) == (r.status == S.NOT_MEASURED) for r in rows)


def test_a_full_run_whose_every_bar_passes_exits_0(tmp_path, scorers):
    code, rows = scorecard(tmp_path, S.SLIDERS, "full")
    assert sorted((r.slider, r.bar, r.stock) for r in rows) == listed(S.SLIDERS)
    assert all(r.status == S.PASS for r in rows) and code == 0


def colour_bars_of(stock):
    bars = json.loads((S.C.OUT / "bars.json").read_text())["bars"]
    return {(S.colour_bar(v, m), stock) for s in FAMILIES["colour"] for v, ms in bars[s][stock].items() for m in ms}


@pytest.mark.parametrize("family, drop, missing", [
    ("dehaze", ("dehaze", "r-photo-disco"),
     {(b, s) for s in S.STOCKS
      for b in ("frame r-photo-disco, change", "fidelity, mean change", "fidelity, mean lRms")}),
    ("detail", ("detail", "texture", -50),
     {("texture -50, mean crop_rmse", "both"),
      ("texture -50, parity: rms ΔL* over the crop against the prototype's change", "both")}),
    ("colour", ("colour", "kodak-gold-200"), colour_bars_of("kodak-gold-200")),
])
def test_a_full_run_that_scored_part_of_a_bar_or_none_of_it_fails_on_that_bar(tmp_path, scorers, family, drop, missing):
    scorers.add(drop)
    code, rows = scorecard(tmp_path, FAMILIES[family], "full")
    assert code == 1
    assert sorted((r.slider, r.bar, r.stock) for r in rows) == listed(FAMILIES[family])
    assert {(r.bar, r.stock) for r in rows if r.status != S.PASS} == missing
    assert all(r.status == S.ERROR for r in rows if (r.bar, r.stock) in missing)


def test_a_scorers_row_for_a_bar_off_the_list_or_a_second_row_for_one_is_an_error():
    a, b = S.Row("dehaze", "a", "s", limit=1.0), S.Row("dehaze", "b", "s", limit=1.0)
    scored = [S.Row("dehaze", "a", "s", 0.5, 1.0, S.PASS), S.Row("dehaze", "a", "s", 2.0, 1.0, S.FAIL),
              S.Row("dehaze", "c", "s", 0.5, 1.0, S.PASS)]
    rows = S.reconcile([a, b], scored, whole=True)
    assert [(r.bar, r.measured, r.status) for r in rows] == [
        ("a", 0.5, S.PASS), ("b", None, S.ERROR), ("a", 2.0, S.ERROR), ("c", 0.5, S.ERROR)]


# MARK: The held-out judge added to fit_clarity_round2.py

def test_the_bars_runs_are_the_frames_lightroom_rendered_on_both_stocks():
    bars = R.spike_bars()
    for slider, name in R.SPIKE_CANDIDATES.items():
        for v in R.VALUES:
            assert len(R.bar_runs(slider, v)) == bars[f"{name} {v:+d}"]["runs"]


def runs_for(slider, value, metric, score):
    return [{"slider": slider, "job": j, "stock": s, "value": value, metric: score, "parity": 0.1}
            for j, s in sorted(R.bar_runs(slider, value))]


def test_a_held_out_bar_is_judged_only_on_all_its_runs():
    bars = {"clarity-guided +100": {"metric": "rmse", "bar": 5.8, "held_out": 5.5, "runs": 54}}
    runs = runs_for("clarity", 100, "rmse", 5.7)
    bar, parity = R.judge_spike(runs, bars)
    assert bar["pass"] is True and bar["runs"] == 54 and parity["max"] is None and parity["pass"] is None
    runs[0]["rmse"] = 5.7 + 54 * 0.2
    assert R.judge_spike(runs, bars)[0]["pass"] is False
    assert R.judge_spike(runs[1:], bars)[0]["pass"] is None


def test_the_spike_flags_drop_what_the_scorer_adds_again():
    args = ["raw.ARW", "--stock", "S", "--out", "O", "--no-warmup", "--auto", "--tiff", "--no-lens", "--long-edge", "1752",
            "--print-out", "P"]
    assert R.spike_flags_of(args) == ["--auto", "--tiff", "--no-lens", "--long-edge", "1752"]


# MARK: Through the real spike

@spike_tests
def test_before_the_stages_land_identity_passes_and_every_other_bar_names_its_missing_piece(tmp_path):
    binary = S.CHECKOUT / ".build" / "release" / "argent-spike"
    if any(S.stage(binary, s)[0] is None for s in S.SLIDERS):
        pytest.skip("a stage is built: its bars are the scorecard's full run, not a test")
    rows, _ = S.run(binary, work=tmp_path, log=lambda *a: None)
    assert all(r.status == S.PASS for r in rows if r.bar.startswith("identity: "))
    rest = [r for r in rows if not r.bar.startswith("identity: ")]
    assert all(r.status == S.NOT_BUILT and re.search(r"is not built yet: package [A-G] of docs/presence-plan.md", r.note)
               for r in rest)
    assert S.exit_code(rows) == 3


@spike_tests
def test_the_stability_scorer_on_the_prototype_is_f2s_scale_check(tmp_path):
    rows = D.stability_rows(D.stand_in_spike(tmp_path), json.loads(D.BARS.read_text()), log=lambda *a: None)
    kept = json.loads((D.EVIDENCE / "scale.json").read_text())
    for r in rows:
        job, value = r["bar"].split()[1], r["bar"].split()[2]
        if r["stock"] == "kodak-portra-400":
            want = kept[f"{job} {r['stock']}"]["values"][str(int(value))]
            assert r["measured"] == pytest.approx(want["estimateDE"], abs=1e-6)
            assert r["p99"] == pytest.approx(want["estimateDEp99"], abs=1e-6)


@spike_tests
def test_the_clarity_scorer_on_the_prototype_gives_its_kept_scores_and_parity_zero(tmp_path, monkeypatch):
    monkeypatch.setattr(R, "SCRATCH", tmp_path)
    runs = R.score_spike(R.stand_in_spike(tmp_path), ["p-photo-hazy"], stocks=["kodak-portra-400"], log=lambda *a: None)
    kept = R.kept_runs()
    for r in runs:
        metric = "crop_rmse" if r["slider"] == "texture" else "rmse"
        assert r[metric] == pytest.approx(kept[(r["slider"], r["job"], r["stock"], r["value"])][metric], abs=1e-6)
        assert r["parity"] == 0
    assert len(runs) == 8
