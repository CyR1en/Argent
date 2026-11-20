"""Tests of the mask session kit, with no Lightroom: pytest, from this folder:

    /path/to/.venv/bin/python -I -m pytest -q scripts/lightroom-probe/test_masks.py

* the plan: ids, tables, job files and their time estimate;
* every job file parses (the plug-in's grammar, mirrored in Python) and every table it names decodes, validates and
  round-trips in a real Lua 5.1 (micro's embedded interpreter, which is all this Mac has; skipped without it);
* Probe.lua's runner against a fake Lightroom (the menu command, the catalog guard, STOP, the gate, the read-back);
* the analysis against synthetic exports (synth_masks.py) with known laws: it must name them, and when one law is flipped it
  must notice. This is the only test of the analysis possible before the session.

Each synthetic world is about 350 MB of TIFFs under pytest's temp folder; the tests remove them as they go (the unflipped world
stays until the session ends). `--basetemp=DIR` puts them somewhere else.
"""
import json
import os
import pty
import select
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ai_masks  # noqa: E402
import analyze_masks as am  # noqa: E402
import make_charts  # noqa: E402
import mask_models as mm  # noqa: E402
import masks_plan  # noqa: E402
import probe  # noqa: E402
import synth_masks as sm  # noqa: E402

PLUGIN = HERE / "ArgentProbe.lrplugin"
MICRO = shutil.which("micro") or "/opt/homebrew/bin/micro"
needs_micro = pytest.mark.skipif(not Path(MICRO).exists(), reason="micro (a Lua 5.1 engine) is not installed")
SCALE = {c: 0.25 for c in masks_plan.CHARTS}
SCALE["P"] = 0.1


@pytest.fixture(scope="session")
def plan():
    return masks_plan.build()


# MARK: Charts

def test_existing_charts_are_unchanged():
    """The size parameter added to make_charts must not change the bytes of the charts already used (hashes of 2026-10-29's pixels)."""
    import hashlib
    px, _ = make_charts.locality()
    assert hashlib.sha256(px.tobytes()).hexdigest()[:16] == "b6665e6805752dc4"
    recorded = {"dark": "c14480e3457a32a6", "mid": "40d77c6a11232593", "bright": "a39848fd31e9c90a", "white": "3b9f469aff86abfa",
                "split": "7d64a45ddc1e5a9d", "texture": "648a5b10517994c4"}
    for content in make_charts.CONTENT:
        px, layout = make_charts.adaptation(content)
        assert px.shape == (2000, 3000, 3) and hashlib.sha256(px.tobytes()).hexdigest()[:16] == recorded[content], content
    px, layout = make_charts.mask_ramp()
    assert px.shape == (1200, 2000, 3) and np.all(px == px[:1])
    levels = np.log2(px[0, :, 0] / 65535.0)
    assert levels[0] == pytest.approx(-12, abs=0.01) and levels[-1] == pytest.approx(0, abs=0.01)
    px, layout = make_charts.mask_flat()
    assert px.shape == (1000, 1600, 3) and np.log2(px[0, 0, 0] / 65535.0) == pytest.approx(-2.5, abs=0.001)


# MARK: The plan

def test_plan_is_consistent(plan):
    assert len(plan.items) == sum(len(j.items) for j in plan.jobs)
    assert [j.name for j in plan.jobs] == sorted(j.name for j in plan.jobs), "jobs run in the order of their names"
    stems = [i.stem for i in plan.items.values()]
    assert len(stems) == len(set(stems)), "an export is named after its photo, so every item needs its own file name"
    for item in plan.items.values():
        assert all(c.isalnum() or c in "-_+." for c in item.stem), item.stem
        for corr in item.masks or []:
            assert corr["What"] == "Correction" and corr["CorrectionMasks"]
    # every global render and mask names a control the analysis knows
    assert {i.meta["q"] for i in plan.items.values()} >= {"Q1", "Q3", "Q4", "Q5", "Q6", "Q7", "Q8", "Q2", "PP"}
    # the references each job needs come from the same job or an earlier one
    order = {j.name: n for n, j in enumerate(plan.jobs)}
    for item in plan.items.values():
        if item.meta.get("role") == "pair-ab":
            key = f"{item.meta['a']}{masks_plan.fmt(item.meta['va'])}_{item.meta['b']}{masks_plan.fmt(item.meta['vb'])}"
            glob = plan.get(masks_plan.gid("R", [(item.meta["a"], item.meta["va"]), (item.meta["b"], item.meta["vb"])]))
            assert order[glob.job] <= order[item.job]


def test_the_session_fits_an_hour(plan):
    est = plan.estimate()
    assert est["total_min"] <= 60, est
    assert est["run_min"] <= 20
    first = {j.name: n for n, j in enumerate(plan.jobs)}
    # the biggest question (partial coverage) is in the first full job, after the go/no-go
    assert plan.get("R-q1-G1-W+100").job == "m01-partial" and first["m01-partial"] == 1
    assert plan.jobs[0].name == "m00-smoke" and plan.jobs[0].gate >= 1 and len(plan.jobs[0].items) <= 10


def python_validate(corrections):
    """A mirror of MaskJob.validate for the planner's own tables."""
    assert isinstance(corrections, list) and 0 < len(corrections) <= 4
    for c in corrections:
        assert c["What"] == "Correction" and c["CorrectionMasks"]
        for m in c["CorrectionMasks"]:
            assert m["What"] in ("Mask/Gradient", "Mask/CircularGradient", "Mask/RangeMask")
            assert m["MaskBlendMode"] in (0, 1) and isinstance(m["MaskInverted"], bool)
            if m["What"] == "Mask/Gradient":
                assert all(isinstance(m[k], (int, float)) for k in ("ZeroX", "ZeroY", "FullX", "FullY"))
            if m["What"] == "Mask/CircularGradient":
                assert all(isinstance(m[k], (int, float)) for k in ("Top", "Left", "Bottom", "Right", "Angle", "Feather", "Midpoint", "Roundness", "Version"))
            if m["What"] == "Mask/RangeMask":
                r = m["CorrectionRangeMask"]
                nums = [float(x) for x in r["LumRange"].split()]
                assert r["Type"] == 2 and "PointModels" not in r and len(nums) == 4 and nums == sorted(nums) and 0 <= nums[0] and nums[-1] <= 1


def parse_job(text):
    """The plug-in's grammar (Probe.lua parse), in Python: lines of tab-separated fields."""
    job = {"items": []}
    for line in text.splitlines():
        fields = line.split("\t")
        if fields[0] in ("OUT", "MODE", "CATALOG", "GATE", "SETTLE", "NOTE"):
            job[fields[0].lower()] = fields[1]
        elif fields[0] == "ITEM":
            assert len(fields) == 4, line
            settings = dict(kv.split("=") for kv in fields[2].split(";") if kv)
            job["items"].append({"path": fields[1], "settings": {k: float(v) for k, v in settings.items()}, "table": fields[3] or None})
        else:
            raise AssertionError(f"unknown line {line!r}")
    return job


@pytest.fixture(scope="session")
def staged(plan, tmp_path_factory):
    root = tmp_path_factory.mktemp("stage")
    jobs = root / "jobs"
    names = masks_plan.write_plan(plan, root, jobs, root / "charts-dng", allow_missing=True)
    assert names == [j.name for j in plan.jobs]
    return root, jobs


def test_every_job_file_parses(plan, staged):
    root, jobs = staged
    seen_paths = set()
    total = 0
    for job in plan.jobs:
        text = (jobs / f"{job.name}.job").read_text()
        parsed = parse_job(text)
        assert parsed["mode"] == "masks" and parsed["catalog"] == masks_plan.CATALOG_GUARD
        assert Path(parsed["out"]).name == f"exports-{job.name}"
        assert len(parsed["items"]) == len(job.items)
        if job.gate:
            assert int(parsed["gate"]) == job.gate
        for entry, item in zip(parsed["items"], job.items):
            total += 1
            assert entry["path"] not in seen_paths
            seen_paths.add(entry["path"])
            assert Path(entry["path"]).name.startswith(item.stem)
            assert entry["settings"] == {k: float(v) for k, v in item.glob.items()}
            if item.masks:
                table = json.loads(Path(entry["table"]).read_text())
                assert table == json.loads(json.dumps(item.masks))
                python_validate(table)
            else:
                assert entry["table"] is None
    assert total == len(plan.items)
    stored = json.loads((root / "masks-plan.json").read_text())
    assert set(stored["items"]) == set(plan.items)
    # the plan reloads to the same plan
    again = masks_plan.load_plan(root / "masks-plan.json")
    assert [i.id for j in again.jobs for i in j.items] == [i.id for j in plan.jobs for i in j.items]


def test_atomic_job_files(staged):
    _, jobs = staged
    assert not list(jobs.glob("*.tmp"))


def test_local_scales_follow_the_third_party_measurements():
    """LocalExposure2012 = EV / 4 and the others panel / 100 (GW capture 2, MCP-304/317)."""
    assert masks_plan.stored("E", 2.0) == 0.5 and masks_plan.stored("E", -4) == -1.0
    assert masks_plan.stored("W", 50) == 0.5 and masks_plan.stored("B", -100) == -1.0
    c = masks_plan.correction({"E": 1.39, "H": -30}, [masks_plan.full_gradient()])
    assert c["LocalExposure2012"] == 0.3475 and c["LocalHighlights2012"] == -0.3
    inter = masks_plan.intersect(masks_plan.linear((0, 0), (1, 1)))
    assert inter["MaskBlendMode"] == 1 and inter["MaskInverted"] is True, "Intersect is a subtracted, inverted component"


# MARK: Lua

def micro_run(script, env, tmp_path, timeout=60):
    """Runs a Lua script under micro's embedded Lua 5.1 (headless, in a pty, with its own config folder)."""
    cfg = tmp_path / "microcfg"
    cfg.mkdir(exist_ok=True)
    out = Path(env["LRTEST_OUT"])
    out.unlink(missing_ok=True)
    (cfg / "init.lua").write_text(
        f'local ok, err = pcall(dofile, {json.dumps(str(script))})\n'
        f'if not ok then local f = io.open(os.getenv("LRTEST_OUT") .. ".error", "w"); f:write(tostring(err) .. "\\n"); f:close() end\n'
        'os.exit(0)\n')
    full = dict(os.environ, MICRO_CONFIG_HOME=str(cfg), TERM="xterm-256color", **env)
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(MICRO, ["micro"], full)
    start = time.time()
    while time.time() - start < timeout:
        ready, _, _ = select.select([fd], [], [], 0.3)
        if ready:
            try:
                if not os.read(fd, 65536):
                    break
            except OSError:
                break
        done, _ = os.waitpid(pid, os.WNOHANG)
        if done:
            break
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    err = Path(str(out) + ".error")
    assert not err.exists(), err.read_text()
    assert out.exists(), "the Lua script did not run"
    return out.read_text()


@needs_micro
def test_lua_maskjob(plan, staged, tmp_path):
    root, _ = staged
    listing = tmp_path / "tables.txt"
    listing.write_text("\n".join(str(p) for p in sorted((root / "mask-tables").rglob("*.json"))) + "\n")
    text = micro_run(HERE / "lua-tests" / "maskjob_test.lua", {"LRTEST_PLUGIN": str(PLUGIN), "LRTEST_TABLES": str(listing),
                                                               "LRTEST_OUT": str(tmp_path / "lua.out")}, tmp_path)
    assert "LUA-TESTS-PASSED" in text, text
    n = sum(1 for i in plan.items.values() if i.masks)
    assert f"all {n} planned tables decode, validate and round-trip" in text, text


def flow(tmp_path, scenario, plan, catalog="/scratch/Argent-masks-session.lrcat", before=None, only=("m00-smoke", "m01-partial")):
    """Probe.lua against the fake Lightroom: a plug-in folder with the jobs folder substituted, jobs staged, run."""
    root, jobs, plug = tmp_path / "root", tmp_path / "jobs", tmp_path / "plugin"
    for p in (root, plug):
        p.mkdir()
    masks_plan.write_plan(plan, root, jobs, root / "charts-dng", allow_missing=True, only=list(only))
    for job in only:
        (root / f"exports-{job}").mkdir(exist_ok=True)
    for name in ("Info.lua", "Init.lua", "RunNow.lua", "MaskJob.lua"):
        shutil.copy(PLUGIN / name, plug / name)
    (plug / "Probe.lua").write_text((PLUGIN / "Probe.lua").read_text().replace("'@JOBDIR@'", f"'{jobs}'"))
    if before:
        before(jobs)
    text = micro_run(HERE / "lua-tests" / "probe_flow_test.lua",
                     {"LRTEST_PLUGIN": str(plug), "LRTEST_JOBDIR": str(jobs), "LRTEST_SCENARIO": scenario, "LRTEST_CATALOG": catalog,
                      "LRTEST_OUT": str(tmp_path / "flow.out")}, tmp_path)
    return text, root, jobs


@needs_micro
def test_runner_normal(plan, tmp_path):
    text, root, jobs = flow(tmp_path, "normal", plan)
    n = sum(len(plan.jobs[i].items) for i in (0, 1))
    assert "FLOW-DONE" in text and f"exported\t{n}" in text and (jobs / "ALLDONE").exists()
    assert sorted(p.name for p in jobs.glob("*.processed")) == ["m00-smoke.processed", "m01-partial.processed"]
    assert "masks=1" not in text, "the tables must be taken off the photos again"
    done = (jobs / "m00-smoke.done").read_text()
    assert "INFO\tplugin\t1.3.0" in done and f"DONE\t{len(plan.jobs[0].items)}" in done and "WARN" not in done
    assert len(list((root / "exports-m01-partial" / "readback").glob("*.json"))) == len(plan.jobs[1].items)
    timing = (root / "exports-m00-smoke" / "timing.tsv").read_text()
    assert timing.startswith("phase\tseconds\titems") and "total" in timing
    read = json.loads((root / "exports-m00-smoke" / "readback" / "m00-smoke_R-smoke-G1-E+1.json").read_text())
    assert read["enable"] is True and read["ProcessVersion"] == "15.4" and read["written"][0]["LocalExposure2012"] == 0.25
    notes = [l for l in (jobs / "m01-partial.done").read_text().splitlines() if l.startswith("NOTE")]
    assert not notes, "a faithful fake Lightroom keeps everything"


@needs_micro
def test_runner_gate_stops_the_run_when_tables_come_back_empty(plan, tmp_path):
    text, root, jobs = flow(tmp_path, "dropall", plan)
    assert "exported\t0" in text and (jobs / "STOPPED").exists() and (jobs / "m01-partial.job").exists()
    done = (jobs / "m00-smoke.done").read_text()
    assert "WARN\tmask-readback" in done and "aborted" in done


@needs_micro
def test_runner_logs_clamped_fields_as_notes(plan, tmp_path):
    text, root, jobs = flow(tmp_path, "clamp", plan)
    notes = [l for l in (jobs / "m01-partial.done").read_text().splitlines() if l.startswith("NOTE")]
    assert any("CorrectionAmount: wrote 3, read 1" in n for n in notes)


@needs_micro
def test_runner_cancel_and_stop(plan, tmp_path):
    text, root, jobs = flow(tmp_path, "cancel", plan)
    assert "exported\t0" in text and (jobs / "STOPPED").exists()
    sub = tmp_path / "again"
    sub.mkdir()
    text, root, jobs = flow(sub, "normal", plan, before=lambda j: (j / "STOP").write_text(""))
    assert "applied\t0" in text and not list(jobs.glob("*.done"))


@needs_micro
def test_runner_stops_in_the_middle_of_an_export(plan, tmp_path):
    text, root, jobs = flow(tmp_path, "stopmid", plan)
    assert "exported\t3" in text, text
    assert (jobs / "STOPPED").exists() and (jobs / "m01-partial.job").exists()
    assert "canceled during the export" in (jobs / "m00-smoke.done").read_text()
    assert "masks=1" not in text, "the tables are taken off the photos even when the run is stopped"


@needs_micro
def test_runner_refuses_the_wrong_catalog_and_the_background_poll(plan, tmp_path):
    text, root, jobs = flow(tmp_path, "wrong", plan, catalog="/Users/someone/Pictures/Lightroom/Lightroom Catalog.lrcat")
    assert "applied\t0" in text and "dialog\tmessage" in text and len(list(jobs.glob("*.job"))) == 2
    sub = tmp_path / "poll"
    sub.mkdir()
    text, root, jobs = flow(sub, "poll", plan)
    assert "applied\t0" in text and len(list(jobs.glob("*.job"))) == 2


# MARK: Lens jobs

@needs_micro
@pytest.mark.parametrize("mode", [None, "lens-defaults", "lens-ranges"])
@pytest.mark.parametrize("catalog,scenario,allowed", [
    ("/scratch/Argent-lens-session.lrcat", "normal", True),
    ("/scratch/Argent-lens-session.lrcat", "poll", False),
    ("/scratch/Owner.lrcat", "normal", False),
    ("/scratch/argent-lens-session/Owner.lrcat", "normal", False),
])
def test_lens_catalog_guard(plan, tmp_path, mode, catalog, scenario, allowed):
    def stage(folder):
        for path in folder.glob("*.job"):
            path.unlink()
        lines = ["CATALOG\targent-lens-session", f"OUT\t{tmp_path / 'exports'}"]
        if mode:
            lines.append(f"MODE\t{mode}")
        lines.append("ITEM\t/scratch/chart.dng\t")
        (folder / "lens.job").write_text("\n".join(lines) + "\n")

    text, root, folder = flow(tmp_path, scenario, plan, catalog=catalog, before=stage)
    assert "RUNPENDING-ERROR" not in text, text
    if allowed:
        assert "imported\t1" in text and (folder / "lens.processed").exists(), text
        assert "ERROR" not in (folder / "lens.done").read_text()
        assert f"applied\t{0 if mode == 'lens-defaults' else 1}" in text, text
        if mode == "lens-ranges":
            assert (tmp_path / "exports/ranges/chart.json").is_file()
        else:
            assert "exported\t1" in text, text
    else:
        assert "imported\t0" in text and "applied\t0" in text and "exported\t0" in text, text
        assert (folder / "lens.job").exists() and not list(folder.glob("*.done"))


@pytest.mark.parametrize("family", ["defaults", "ranges", "profile", "amounts", "ca", "defringe",
                                    "fringe-neutral", "camera-amounts"])
def test_lens_writer_requires_session_catalog(tmp_path, monkeypatch, family):
    sys.path.insert(0, str(HERE.parent / "lens-correction"))
    import lightroom_jobs
    folder = tmp_path / "jobs"
    folder.mkdir()
    (folder / "READY").touch()
    source = tmp_path / "chart.dng"
    source.write_bytes(b"synthetic")
    monkeypatch.setattr(lightroom_jobs.jobs, "jobs_dir", lambda: folder)
    lightroom_jobs.write(family, "lens", source, folder)
    lines = (folder / "lens.job").read_text().splitlines()
    assert lines[0] == "CATALOG\tArgent-lens-session-lc3-r2"
    if family == "amounts":
        items = [line.split("\t") for line in lines if line.startswith("ITEM\t")]
        assert len(items) == 11
        for item, (control, amount) in zip(items[1:], [(c, a) for c in ("Distortion", "Vignetting")
                                                     for a in (0, 50, 100, 150, 200)]):
            settings = dict(part.split("=", 1) for part in item[2].split(";"))
            assert settings["LensProfileEnable"] == "1"
            assert settings["LensProfileSetup"] == "Custom"
            assert settings[f"LensProfile{control}Scale"] == str(amount)
            other = "Vignetting" if control == "Distortion" else "Distortion"
            assert settings[f"LensProfile{other}Scale"] == "0"


# MARK: The models

def test_pchip_is_monotone_and_hits_its_knots():
    x = np.array([-2, -1, -0.5, 0, 0.5, 1, 2.0])
    y = 100 / (1 + np.exp(-(x + 0.2) / 0.8))
    q = mm.pchip(x, y, np.linspace(-2, 2, 801))
    assert np.all(np.diff(q) >= -1e-12) and np.allclose(mm.pchip(x, y, x), y)


def test_edge_fit_names_the_shape():
    t = np.linspace(-0.2, 1.4, 400)
    for name, S in mm.PROFILES.items():
        best = mm.fit_edge(t, 1 - S((t - 0.3) / 0.5))[0]
        assert best["family"] == name and best["a"] == pytest.approx(0.3, abs=0.01) and best["b"] == pytest.approx(0.8, abs=0.01)


def test_algebras_are_self_consistent():
    c, v = np.random.default_rng(1).random((2, 500))
    for f in mm.ALGEBRAS.values():
        assert np.allclose(f["int"](c, v), f["sub"](c, 1 - v))
        assert np.all((f["add"](c, v) >= -1e-12) & (f["add"](c, v) <= 1 + 1e-12))


def test_r5_arithmetic_matches_the_closed_form():
    """RampTables.r5_level against R5's SceneCPU.gains written out for two layers (local first, then global in order)."""
    x = np.linspace(-12, 0, 600)
    base = 100 / (1 + np.exp(-(x + 2.5) / 1.6))
    glob = {("W", 50.0): 100 / (1 + np.exp(-(x + 2.5 - 0.4) / 1.6)), ("H", -50.0): 100 / (1 + np.exp(-(x + 2.5 + 0.3) / 1.6)),
            ("B", -50.0): 100 / (1 + np.exp(-(x + 2.5 + 0.2) / 1.6))}
    t = mm.RampTables(x, base, glob)
    layers = [{"W": 50.0, "E": 0.5}, {"H": -50.0, "B": -50.0}]
    c = [0.7, 0.4]
    level = t.r5_level(x, x, {}, layers, c)
    e = 0.7 * 0.5
    u, ub = x + e, x + e
    tt = 0.4 * t.gain("H", -50.0, ub)
    tt = tt + 0.7 * t.gain("W", 50.0, u + tt)
    tt = tt + 0.4 * t.gain("B", -50.0, u + tt)
    assert np.allclose(level, u + tt)
    # coverage 0 is the picture as it was; coverage 1 over everything with one layer is the panel
    assert np.allclose(t.r5_lstar(x, x, {}, layers, [0, 0]), base)
    assert np.allclose(t.r5_level(x, x, {}, [{"W": 50.0}], [1.0]), t.r5_level(x, x, {"W": 50.0}, [], []))


# MARK: The analysis against known laws

def run_world(tmp_path_factory, world, name, keep=False):
    """Renders the whole plan under `world` (about 350 MB at the test scale), analyses it, and removes the exports unless `keep`."""
    root = tmp_path_factory.mktemp(name)
    plan = masks_plan.build()
    sm.render_plan(plan, world, root, SCALE)
    data = am.Data(plan, root, block=2)
    res = am.run_all(data)
    if not keep:
        shutil.rmtree(root, ignore_errors=True)
    return res, data


WORLD_R5 = sm.WORLDS["r5"]


@pytest.fixture(scope="session")
def base_run(tmp_path_factory):
    res, data = run_world(tmp_path_factory, WORLD_R5, "r5", keep=True)
    yield res, data
    shutil.rmtree(data.root, ignore_errors=True)


def test_check_reads_a_clean_session(base_run):
    res, data = base_run
    lines, ok = am.check(data, allow_scaled=True)
    assert ok, "\n".join(lines)


def test_r5_world_is_recovered(base_run):
    """The synthetic Lightroom obeys exactly what R5 and R8 assumed: the analysis must say so, with errors near its floor."""
    res, _ = base_run
    assert all(r.status == "ok" for r in res.values()), {q: r.status for q, r in res.items()}
    v = {q: r.verdict for q, r in res.items()}
    assert v["q1"]["law"] == "gain" and v["q1"]["settled"] and v["q1"]["current_rule_error"]["max"] < 0.4
    assert v["q2"]["best"] == "r5" and v["q2"]["order_matters"] and v["q2"]["current_rule_error"]["rms"] < 0.3
    assert v["q3"]["best"] == "slider" and v["q3"]["linear_to"] == 1 and v["q3"]["clamp"] == pytest.approx(1.0, abs=0.01)
    r4 = v["q4"]["radial"]
    assert "inward" in r4["form"] and r4["family"] == "smoothstep"
    for f in (10, 25, 50, 75, 100):
        assert r4[f]["a"] == pytest.approx(1 - f / 100, abs=0.02) and r4[f]["b"] == pytest.approx(1.0, abs=0.02)
    gv = v["q4"]["linear"]["GV"]
    assert gv["family"] == "smoothstep" and gv["a"] == pytest.approx(0, abs=0.02) and gv["b"] == pytest.approx(1, abs=0.02)
    assert v["q4"]["linear"]["GD"]["space"] == "pixels" and v["q4"]["radial"]["resolution"] < 0.1
    assert v["q5"]["algebra"] == "prob" and v["q5"]["r8_dL_max"] < 0.3
    assert v["q6"]["base_shared"] and v["q6"]["adaptation"] == "frame"
    assert v["q7"]["equal"] and v["q7"]["order"] == "panel-first"
    assert v["q8"]["exposure_scale"] == pytest.approx(1.0, abs=0.01)
    assert v["q8"]["clip_pos"]["stored"] == 1.0 and v["q8"]["clip_neg"]["stored"] == -1.0


def test_report_and_summary(base_run, tmp_path):
    res, data = base_run
    rows = am.summarize(res)
    assert len(rows) == 8 and all(r[3].startswith("KEEP") for r in rows), rows
    lines, _ = am.check(data, allow_scaled=True)
    path = am.write_report(res, data, tmp_path, data.plan, lines, "test")
    text = path.read_text()
    assert "## One page" in text and text.count("## Q") == 8
    assert json.loads((tmp_path / "results.json").read_text())["q1"]["verdict"]["law"] == "gain"


# law -> (world change, what the analysis must now say). One law at a time, from the R5 world.
FLIPS = {
    "coverage scales the slider": (dict(coverage="slider"), lambda v: v["q1"]["law"] == "slider" and v["q1"]["current_rule_error"]["max"] > 2),
    "coverage blends in L*": (dict(coverage="blendL"), lambda v: v["q1"]["best"] == "blendL" and v["q1"]["exposure_law"] == "blendL"),
    "coverage blends in luminance": (dict(coverage="blendY"), lambda v: v["q1"]["best"] == "blendY" and v["q1"]["exposure_law"] == "blendY"),
    "linear profile": (dict(profile="linear"), lambda v: v["q4"]["linear"]["GV"]["family"] == "linear" and v["q4"]["linear"]["GV"]["r8_dL_max"] > 1),
    "smootherstep profile": (dict(profile="smootherstep"), lambda v: v["q4"]["linear"]["GV"]["family"] == "smootherstep"),
    "feather centred on the outline": (dict(radial="straddle"), lambda v: "centred" in v["q4"]["radial"]["form"] and v["q4"]["radial"][50]["r8_dL_max"] > 3),
    "min/max algebra": (dict(algebra="minmax"), lambda v: v["q5"]["algebra"] == "minmax" and v["q5"]["r8_dL_max"] > 1),
    "Lukasiewicz algebra": (dict(algebra="luk"), lambda v: v["q5"]["algebra"] == "luk"),
    "masks sum their sliders": (dict(overlap="sum"), lambda v: v["q2"]["best"] == "sum" and not v["q2"]["order_matters"] and v["q2"]["current_rule_error"]["max"] > 3),
    "masks apply strictly one after another": (dict(overlap="seq"), lambda v: v["q2"]["best"] == "seq" and v["q2"]["order_matters"]),
    "Amount scales the gain": (dict(amount="gain"), lambda v: v["q3"]["best"] == "gain" and v["q3"]["current_rule_error"]["max"] > 2),
    "a mask reads its own base": (dict(base="masked"), lambda v: v["q6"]["base_shared"] is False),
    "a mask adapts to its own region": (dict(adapt="region"), lambda v: v["q6"]["adaptation"] == "region"),
    "the masks go before the panel": (dict(order="masks-first"), lambda v: v["q7"]["order"] == "mask-first"),
    "local Exposure is stored x3": (dict(exposure_scale=3.0), lambda v: v["q8"]["exposure_scale"] == pytest.approx(0.75, abs=0.02)),
    "local Exposure clamps at 3 EV": (dict(exposure_clip=3.0), lambda v: v["q8"]["clip_pos"]["stored"] == 0.75),
    "Amount clamps at 2": (dict(amount_max=2.0), lambda v: v["q3"]["linear_to"] == 2),
    "the gradient is measured in normalized axes": (dict(gradient_space="normalized"), lambda v: v["q4"]["linear"]["GD"]["space"] == "normalized"),
    "a luminance range does not cover the frame": (dict(lum_full=False), lambda v: v["q7"]["by_construction"]["lum"] > 3),
}


@pytest.mark.parametrize("law", sorted(FLIPS))
def test_the_analysis_notices_a_flipped_law(law, tmp_path_factory, base_run):
    change, check = FLIPS[law]
    res, _ = run_world(tmp_path_factory, replace(WORLD_R5, name=law, **change), "flip")
    verdicts = {q: r.verdict for q, r in res.items()}
    assert check(verdicts), f"{law}: {json.dumps({q: {k: v for k, v in x.items() if k in ('law', 'best', 'algebra', 'order') } for q, x in verdicts.items()}, default=str)[:600]}"
    base = {q: r.verdict for q, r in base_run[0].items()}
    assert not check(base), f"{law}: the check also passes on the unflipped world, so it proves nothing"


# L2's AI masks (ai_masks.py, MODE masks-ai)

FRACTIONS = ai_masks.SERIES[1][1]


def test_the_two_series_blend_by_base_luminance():
    base = np.array([[0.001, 0.0325, 0.5, 0.5, 0.001]], np.float32)
    shadows = np.array([[0.2, 0.2, 0.2, 0.2, 0.2]], np.float32)
    highlights = np.array([[0.8, 0.8, 0.8, 0.8, 0.8]], np.float32)
    valid_shadows = np.array([[True, True, True, False, False]])
    valid_highlights = np.array([[True, True, True, True, False]])
    alpha, valid = ai_masks.blend(base, shadows, valid_shadows, highlights, valid_highlights)
    assert alpha[0, 0] == pytest.approx(0.2) and alpha[0, 2] == pytest.approx(0.8)
    assert alpha[0, 1] == pytest.approx(0.5, abs=0.01), "the ramp's middle"
    assert alpha[0, 3] == pytest.approx(0.8), "only the highlight series is valid there"
    assert valid.tolist() == [[True, True, True, True, False]]


def test_recovery_inverts_a_known_coverage():
    """The series-inversion on made-up pictures: a tone curve that bends, coverage from 0 to 1, a dark patch with no signal."""
    h, w = 64, 256
    truth = np.tile(np.linspace(0, 1, w, dtype=np.float32), (h, 1))
    scene = np.tile(np.logspace(-3, -0.1, h, dtype=np.float32)[:, None], (1, w))
    def curve(y, stops):
        v = y * 2.0 ** stops
        return (v / (1 + 0.4 * v)).astype(np.float32)
    ev = -1.0
    base = curve(scene, 0)
    layers = [curve(scene, ev * f) for f in FRACTIONS]
    masked = curve(scene, ev * truth)
    alpha, valid = ai_masks.invert_series(base, layers, FRACTIONS, masked)
    assert valid.all()
    assert np.abs(alpha - truth).max() < 0.002
    # a pixel with no signal is not valid, and is filled from what is around it
    base[10:20, 100:120] = 0
    alpha, valid = ai_masks.invert_series(base, layers, FRACTIONS, masked)
    assert not valid[12, 110] and valid[30, 110]
    filled = ai_masks.fill_invalid(alpha, valid)
    assert np.abs(filled - truth)[valid].max() < 0.002
    assert abs(filled[15, 110] - truth[15, 110]) < 0.05


def test_recovery_at_a_flat_end_reads_full_coverage():
    """A dark pixel whose response clips to black partway along the series, masked at full coverage, reads 1, not the last step below it."""
    base = np.array([[0.002]], np.float32)
    fractions = (0.25, 0.5, 0.75, 1.0)
    layers = [np.array([[v]], np.float32) for v in (0.0005, 0.0, 0.0, 0.0)]
    alpha, valid = ai_masks.invert_series(base, layers, fractions, np.array([[0.0]], np.float32))
    assert alpha[0, 0] == pytest.approx(1.0) and valid[0, 0]
    # an unmasked pixel in the same series stays at 0
    alpha, _ = ai_masks.invert_series(base, layers, fractions, np.array([[0.002]], np.float32))
    assert alpha[0, 0] == pytest.approx(0.0)


def test_recovery_under_a_positive_exposure():
    h, w = 8, 64
    truth = np.tile(np.linspace(0, 1, w, dtype=np.float32), (h, 1))
    base = np.full((h, w), 0.1, np.float32)
    ev = 1.0
    layers = [(base * 2.0 ** (ev * f)).astype(np.float32) for f in FRACTIONS]
    masked = (base * 2.0 ** (ev * truth)).astype(np.float32)
    alpha, valid = ai_masks.invert_series(base, layers, FRACTIONS, masked)
    assert valid.all() and np.abs(alpha - truth).max() < 0.002


def test_known_gradient_runs_from_full_to_zero():
    g = ai_masks.known_gradient(2000, 3000, (0.5, 0.15), (0.5, 0.85))
    assert g.shape == (2000, 3000)
    assert g[0, 1500] > 0.999 and g[-1, 1500] < 0.001
    mid = g[1000, 1500]
    assert 0.3 < mid < 0.7


def test_the_ai_job_file_has_what_the_plugin_reads(tmp_path):
    root = tmp_path / "l2"
    (root / "jobs").mkdir(parents=True)
    (root / "jobs" / "READY").write_text("x")
    raws = tmp_path / "raws"
    raws.mkdir()
    for name in ("DSC04060", "DSC04087", "DSC04100"):
        (raws / f"{name}.ARW").write_bytes(b"raw")
    frames = tmp_path / "frames.json"
    frames.write_text(json.dumps({"sky": ["DSC04100"], "subject": ["DSC04087"], "water": []}))
    ai_masks.write_job(root, frames, raws)
    lines = (root / "jobs" / "l2.job").read_text().splitlines()
    assert lines[0] == "CATALOG\targent-masks-session" and "MODE\tmasks-ai" in lines
    assert [l.split("\t")[1] for l in lines if l.startswith("SERIES")] == ["-1", "-4"]
    items = [l.split("\t") for l in lines if l.startswith("ITEM")]
    assert [i[2] for i in items] == ["KIND=sky", "KIND=subject", "KIND=table", "KIND=table"]
    assert all(i[1].endswith(".arw") and Path(i[1]).exists() for i in items)
    table = json.loads(Path(items[2][3]).read_text())
    assert table[0]["LocalExposure2012"] == -0.25 and table[0]["CorrectionMasks"][0]["What"] == "Mask/Gradient"


@needs_micro
def test_runner_masks_ai(tmp_path):
    """MODE masks-ai against the fake Lightroom: a mask per photo where one comes, the states exported, a photo with none recorded."""
    root, jobs, plug = tmp_path / "root", tmp_path / "jobs", tmp_path / "plugin"
    jobs.mkdir()
    plug.mkdir()
    for name in ("Info.lua", "Init.lua", "RunNow.lua", "MaskJob.lua"):
        shutil.copy(PLUGIN / name, plug / name)
    (plug / "Probe.lua").write_text((PLUGIN / "Probe.lua").read_text().replace("'@JOBDIR@'", f"'{jobs}'"))
    (root / "inputs").mkdir(parents=True)
    table = root / "t.json"
    table.write_text(json.dumps([masks_plan.correction({"E": -1}, [masks_plan.linear((0.5, 0.1), (0.5, 0.9))], name="v")]))
    paths = {n: root / "inputs" / f"{n}.arw" for n in ("sky-a", "nosky-b", "subject-c", "val")}
    for p in paths.values():
        p.write_bytes(b"x")
    (jobs / "l2.job").write_text("\n".join(["CATALOG\targent-masks-session", "MODE\tmasks-ai", f"OUT\t{root / 'exports'}", "SERIES\t-1\t0.25,0.5,0.75,1",
                                            "SERIES\t-4\t0.5,1", f"ITEM\t{paths['sky-a']}\tKIND=sky",
                                            f"ITEM\t{paths['nosky-b']}\tKIND=sky", f"ITEM\t{paths['subject-c']}\tKIND=subject",
                                            f"ITEM\t{paths['val']}\tKIND=table\t{table}"]) + "\n")
    text = micro_run(HERE / "lua-tests" / "probe_flow_test.lua",
                     {"LRTEST_PLUGIN": str(plug), "LRTEST_JOBDIR": str(jobs), "LRTEST_SCENARIO": "masksai",
                      "LRTEST_CATALOG": "/scratch/Argent-masks-session-l2.lrcat", "LRTEST_OUT": str(tmp_path / "flow.out")}, tmp_path)
    assert "FLOW-DONE" in text and "RUNPENDING-ERROR" not in text, text
    ai = (root / "exports" / "ai.tsv").read_text()
    assert "sky-a\tsky\tmade" in ai and "subject-c\tsubject\tmade" in ai and "nosky-b\tsky\tnone" in ai
    exported = root / "exports"
    for masked in ("masked-e-100", "masked-e-400"):
        assert sorted(p.name for p in (exported / masked).glob("*.tif")) == ["sky-a.tif", "subject-c.tif", "val.tif"], masked
    for state in ("full-e-100-0250", "full-e-100-1000", "full-e-400-0500", "full-e-400-1000", "base"):
        assert sorted(p.name for p in (exported / state).glob("*.tif")) == ["nosky-b.tif", "sky-a.tif", "subject-c.tif", "val.tif"], state
    saved = json.loads((exported / "tables" / "sky-a.json").read_text())
    assert saved[0]["CorrectionMasks"][0]["MaskDigest"] == "abc123"
    done = (jobs / "l2.done").read_text()
    assert "ERROR" not in done, done
    assert (jobs / "l2.processed").exists() and (jobs / "ALLDONE").exists()
