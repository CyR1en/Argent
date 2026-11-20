"""Tests of the Presence probe kit, with no Lightroom:

    /path/to/.venv/bin/python -I -m pytest -q scripts/lightroom-probe/test_presence.py

* every chart's layout tells the truth about its pixels, and the charts rebuild to the same bytes;
* jobs.py: the Presence variants, the neutral sidecar and profile on raws only, and `run` refusing a job the
  installed plug-in would misread;
* presence_stats.py reads what an export says it applied, and its statistics move the way they should;
* presence_plan.py: every pair of the combinations has its singles, and the plan fits the disk it was given.
"""
import hashlib
import struct
import sys
from pathlib import Path

import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import jobs  # noqa: E402
import make_charts  # noqa: E402
import presence_charts as pc  # noqa: E402
import presence_stats as ps  # noqa: E402

CODE = 1.5 / 65535


@pytest.fixture(scope="module")
def charts():
    return {name: make() for name, make in pc.CHARTS.items() if name not in pc.DECODED}


def region_pixels(chart, region):
    """A region's values as the DNG stores them: quantized to 16 bits."""
    x0, y0, x1, y1 = region["box"]
    return np.round(np.clip(chart.img[y0:y1, x0:x1].astype(np.float64), 0, 1) * 65535) / 65535


# MARK: Charts

def test_every_region_is_inside_its_chart_and_nothing_clips(charts):
    for name, chart in charts.items():
        h, w, _ = chart.img.shape
        assert chart.regions, name
        for r in chart.regions:
            x0, y0, x1, y1 = r["box"]
            assert 0 <= x0 < x1 <= w and 0 <= y0 < y1 <= h, (name, r["box"])
            assert not r.get("clipped"), (name, r["box"])
        assert chart.img.min() >= 0 and chart.img.max() <= 1, name


def test_gratings_and_bars_hold_the_values_their_layouts_give(charts):
    checked = 0
    for name, chart in charts.items():
        for r in chart.regions:
            x0, y0, x1, y1 = r["box"]
            row = region_pixels(chart, r)[(y1 - y0) // 2, :, 1]
            if r["kind"] == "grating":
                x = np.arange(x0, x1)
                want = pc.MID * 2.0 ** (r["meanStops"] + r["amplitudeStops"] * np.sin(2 * np.pi * (x - r["x0"] + 0.5) / r["periodPx"]))
                assert np.allclose(row, want, atol=CODE), (name, r["box"])
                checked += 1
            elif r["kind"] == "bar":
                a, b = r["highColumns"]
                want = np.full(x1 - x0, pc.MID * 2.0 ** r["lowStops"])
                want[a - x0:b - x0] = pc.MID * 2.0 ** r["highStops"]
                assert np.allclose(row, want, atol=CODE), (name, r["box"])
                checked += 1
    assert checked > 300


def test_a_grating_swings_by_its_amplitude_in_stops(charts):
    chart = charts["p-grating-m2"]
    r = next(r for r in chart.regions if r["kind"] == "grating" and r["periodPx"] == 64 and r["amplitudeStops"] == 0.8)
    stops = np.log2(region_pixels(chart, r)[0, :, 0] / pc.MID)
    assert stops.max() == pytest.approx(-2 + 0.8, abs=0.01) and stops.min() == pytest.approx(-2 - 0.8, abs=0.01)


def test_patches_hold_their_colour_and_sit_where_the_grid_says(charts):
    chart = charts["p-colour-grid"]
    patches = [r for r in chart.regions if r["kind"] == "patch"]
    assert len(patches) == 5 * 24 * 8 + 5 * len(pc.SKIN_HUES) * 8 + len(pc.NEUTRAL_L) + 4 * 24 + len(pc.PRIMARIES)
    for r in patches:
        px = region_pixels(chart, r)
        assert np.allclose(px, np.array(r["rgb"]), atol=CODE), r["box"]
        nominal = r.get("nominal")
        if nominal and nominal.get("C", 0) > 1:
            L, C, h = r["lch"]
            assert L == pytest.approx(nominal["L"], abs=0.01) and C == pytest.approx(nominal["C"], abs=0.01)
            assert (h - nominal["h"] + 180) % 360 - 180 == pytest.approx(0, abs=0.01)
        if nominal and nominal.get("fractionOfEdge") == 1.0:
            rgb = np.array(r["rgb"])
            assert min(rgb.min(), 1 - rgb.max()) < 1e-3, r["box"]
    boxes = sorted(tuple(r["box"]) for r in patches)
    for a, b in zip(boxes, boxes[1:]):
        assert not (a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]), (a, b)


def test_chroma_gratings_keep_their_luminance(charts):
    chart = charts["p-colour-texture"]
    for r in (r for r in chart.regions if r["kind"] == "chroma grating"):
        px = region_pixels(chart, r)[0]
        y = px @ pc.REC2020_Y
        assert np.ptp(y) / y.mean() < 2e-3, r["ground"]
        assert np.ptp(px, axis=0).max() > 0.01, r["ground"]


def test_noise_patches_have_their_spread(charts):
    chart = charts["p-colour-texture"]
    for r in (r for r in chart.regions if r["kind"] == "luminance noise"):
        stops = np.log2(region_pixels(chart, r)[..., 1] / (pc.MID * 2.0 ** r["meanStops"]))
        assert stops.std() == pytest.approx(r["sigma"], rel=0.03) and abs(stops.mean()) < 0.01


def test_haze_is_the_scene_seen_through_the_transmission(charts):
    W, H = pc.HAZE_SIZE
    scene = pc.haze_texture(W, H)
    hazy = charts["p-haze-two"]
    t = 1 - 0.8 * (np.arange(W) + 0.5) / W
    for y, air in ((100, "blue"), (H - 100, "warm")):
        want = scene[y] * t[:, None] + np.array(pc.AIRLIGHT[air]) * (1 - t)[:, None]
        assert np.allclose(hazy.img[y], want, atol=1e-6)
    assert np.allclose(charts["p-haze-none"].img, scene, atol=1e-6)
    darkest = scene.min(axis=-1)
    assert np.mean(darkest < pc.MID / 4) > 0.05, "the scene needs dark pixels for a dark-channel estimate"


def test_charts_rebuild_to_the_same_bytes():
    for name in ("p-steps-half", "p-haze-none", "p-colour-texture"):
        a, b = pc.CHARTS[name]().pixels(), pc.CHARTS[name]().pixels()
        assert hashlib.sha256(a.tobytes()).digest() == hashlib.sha256(b.tobytes()).digest(), name


def test_the_locality_twin_is_the_old_chart(charts):
    px, _ = make_charts.locality()
    assert np.array_equal(charts["p-locality"].pixels(), px)
    assert charts["p-locality-half"].img.shape == (1200, 1500, 3)


def test_the_tiff_chart_decodes_to_the_dng_values():
    linear = np.linspace(0, 1, 65536)
    g, a, b, c, d = 2.22222900390625, 0.90966796875, 0.09033203125, 0.22222900390625, 0.08099365234375
    t = np.round(pc.itu2020_encode(linear) * 65535) / 65535
    back = np.where(t >= d, (a * t + b) ** g, c * t)
    assert np.abs(back - linear).max() < CODE


def test_written_dng_carries_the_rec2020_matrix(tmp_path):
    layout = pc.write("p-flat-grey", tmp_path)
    data = (tmp_path / "p-flat-grey.dng").read_bytes()
    assert layout["primaries"] == "Rec. 2020"
    want = b"".join(struct.pack("<ii", int(round(x * 10000)), 10000) for x in pc.MATRICES["Rec. 2020"])
    assert want in data


# MARK: jobs.py

@pytest.fixture
def jobs_folder(tmp_path, monkeypatch):
    folder = tmp_path / "jobs"
    folder.mkdir()
    (folder / "READY").write_text("")
    monkeypatch.setattr(jobs, "jobs_dir", lambda: folder)
    return folder


def test_presence_variants_with_sidecar_and_profile_on_raws_only(jobs_folder, tmp_path):
    raw = tmp_path / "frame.ARW"
    raw.write_bytes(b"raw")
    chart = tmp_path / "chart.dng"
    chart.write_bytes(b"dng")
    items = jobs.variant_items("p-x", raw, ["texture", "dehaze"], [-50, 100])
    stems = [p.stem for p, _ in items]
    assert stems == ["p-x_00_base", "p-x_texture_-50", "p-x_texture_+100", "p-x_dehaze_-50", "p-x_dehaze_+100"]
    assert items[2][1] == {"CameraProfile": "Adobe Standard", "Texture": "100"}
    sidecar = items[0][0].with_suffix(".xmp").read_text()
    assert 'crs:ProcessVersion="15.4"' in sidecar and 'crs:ToneCurveName2012="Linear"' in sidecar
    dng_items = jobs.variant_items("p-y", chart, ["vibrance"], [25])
    assert dng_items[1][1] == {"Vibrance": "25"}
    assert not dng_items[0][0].with_suffix(".xmp").exists()


def test_run_refuses_a_masks_job_under_plugin_1_1(jobs_folder, monkeypatch):
    (jobs_folder / "m.job").write_text("MODE\tmasks\nOUT\t/tmp/x\n")
    monkeypatch.setattr(jobs, "installed_version", lambda: (1, 1, 0))
    monkeypatch.setattr(jobs, "lightroom_pid", lambda: pytest.fail("must refuse before touching Lightroom"))
    with pytest.raises(SystemExit, match="would run as a settings job"):
        jobs.run(10, jobs_folder)


def test_a_job_the_poll_has_taken_is_read_from_its_processed_file(jobs_folder):
    (jobs_folder / "a.processed").write_text("OUT\t/tmp/out-a\nITEM\t/x.dng\t\n")
    text = jobs.job_text(jobs_folder / "a.job")
    assert jobs.job_out(text) == Path("/tmp/out-a")
    with pytest.raises(FileNotFoundError):
        jobs.job_text(jobs_folder / "b.job")


# MARK: presence_stats.py

def gamma_icc(gamma=461 / 256):
    """The smallest ICC probe.icc_gamma reads: one rTRC tag, a pure gamma."""
    curve = b"curv" + b"\0" * 4 + struct.pack(">IH", 1, round(gamma * 256)) + b"\0\0"
    head = bytearray(128)
    table = struct.pack(">I", 1) + struct.pack(">4sII", b"rTRC", 128 + 4 + 12, len(curve))
    return bytes(head) + table + curve


def export(path, rgb_linear, xmp_text=""):
    """A TIFF shaped like Lightroom's: 16-bit, ProPhoto with a pure-gamma profile, the XMP in tag 700."""
    encoded = np.round(np.clip(rgb_linear, 0, 1) ** (256 / 461) * 65535).astype("<u2")
    h, w, _ = encoded.shape
    entries = [make_charts.long_(256, w), make_charts.long_(257, h), make_charts.short(258, 16, 16, 16),
               make_charts.short(259, 1), make_charts.short(262, 2), make_charts.short(277, 3), make_charts.short(284, 1),
               (34675, 7, len(gamma_icc()), gamma_icc())]
    if xmp_text:
        entries.append((700, 1, len(xmp_text.encode()), xmp_text.encode()))
    path.write_bytes(make_charts.tiff(entries, encoded))
    return path


def test_settings_are_read_from_the_export_and_the_look_kept_apart(tmp_path):
    xmp = ('<rdf:Description crs:ProcessVersion="15.4" crs:Texture="+100" crs:CameraProfile="Adobe Standard">'
           '<crs:Look><rdf:Description crs:Name="Adobe Color" crs:CameraProfile="Other"/></crs:Look></rdf:Description>')
    path = export(tmp_path / "a.tif", np.full((8, 8, 3), 0.2), xmp)
    values, look = ps.settings(path)
    assert values["Texture"] == "+100" and values["CameraProfile"] == "Adobe Standard" and look == "Adobe Color"
    values, look = ps.settings(export(tmp_path / "b.tif", np.full((8, 8, 3), 0.2), '<x crs:Dehaze="-50"/>'))
    assert values["Dehaze"] == "-50" and look is None


def test_statistics_move_with_detail_colour_and_haze(tmp_path):
    rng = np.random.default_rng(3)
    grey = np.full((256, 256, 3), 0.18)
    detail = grey * 2.0 ** (0.3 * rng.standard_normal((256, 256, 1)))
    colour = grey * np.array([1.6, 0.8, 0.6])
    hazy = grey * 0.5 + 0.3
    base, base_lab = ps.measure(export(tmp_path / "grey.tif", grey))
    stats = {name: ps.measure(export(tmp_path / f"{name}.tif", img), base_lab)[0]
             for name, img in (("detail", detail), ("colour", colour), ("hazy", hazy))}
    assert base["chroma"] < 0.5 and stats["colour"]["chroma"] > 20
    assert stats["detail"]["fine"] > base["fine"] + 0.1 and stats["detail"]["local"] > base["local"] + 0.1
    assert stats["hazy"]["dark"] > base["dark"]
    assert stats["colour"]["dE"] > 10 and base["pixels"] != stats["detail"]["pixels"]
    assert base["black"] == 0 and base["white"] == 0


def test_clipped_pixels_are_counted_by_their_extreme_channel(tmp_path):
    img = np.full((4, 8, 3), 0.3)
    img[0, :2] = [1.2, 0.5, 0.5]
    img[1, :1] = [0.4, 0.0, 0.4]
    stats, _ = ps.measure(export(tmp_path / "clip.tif", img))
    assert stats["white"] == 2 and stats["black"] == 1


# MARK: presence_plan.py

@pytest.fixture(scope="module")
def plan():
    import presence_plan
    if not presence_plan.CHARTS.exists():
        pytest.skip("the charts are not made here (make_charts.py presence)")
    return presence_plan


def test_every_pair_has_its_singles(plan):
    jobs_by_name = plan.by_name()
    raw_singles = {tuple(sorted(s.items())) for _, s in jobs_by_name["p-raw"].items}
    for job in (jobs_by_name["p-combo"], jobs_by_name["p-raw-combos"]):
        own = {tuple(sorted(s.items())) for _, s in job.items}
        for label, settings in job.items:
            for key, value in settings.items():
                single = ((key, value),)
                assert single in own or (job.name == "p-raw-combos" and single in raw_singles), (job.name, label, key)


def test_names_are_prefixed_unique_and_the_plan_fits_the_disk(plan):
    names = [job.name for job in plan.plan()]
    assert len(names) == len(set(names)) and all(n.startswith("p-") for n in names)
    for job in plan.plan():
        labels = [label for label, _ in job.items]
        assert labels[0] == "00_base" and len(labels) == len(set(labels)), job.name
    assert sum(job.bytes() for job in plan.plan()) < 78e9


def test_a_new_window_the_size_of_a_dialog_stops_the_wait():
    before = ["1\t1.0\t0,0\t1640x1025\tLightroom Catalog.lrcat", "2\t0.0\t10,10\t324x793\t"]
    assert jobs.new_dialogs(before, before + ["3\t1.0\t20,450\t277x15\t"]) == []
    assert jobs.new_dialogs(before, before + ["4\t0.0\t300,300\t420x180\t"]) == []
    assert jobs.new_dialogs(before, before + ["5\t1.0\t300,300\t420x180\tLightroom Classic"]) == ["5\t1.0\t300,300\t420x180\tLightroom Classic"]


# MARK: Round 2

def test_the_tone_chart_holds_one_grating_at_each_level_and_the_alone_frames_hold_its_0_stop_cell(charts):
    four = charts["q-tone-four"]
    gratings = [r for r in four.regions if r["kind"] == "grating"]
    assert [r["meanStops"] for r in gratings] == pc.TONE_MEANS
    assert {(r["periodPx"], r["amplitudeStops"]) for r in gratings} == {(64, 0.05)}
    x0, y0, x1, y1 = pc.tone_box(2)
    cell = four.pixels()[y0:y1, x0:x1]
    outside = np.ones(four.img.shape[:2], bool)
    outside[y0:y1, x0:x1] = False
    for ground, level in (("dark", -6.0), ("bright", 2.0), ("ramp", None)):
        alone = charts[f"q-tone-{ground}"]
        assert np.array_equal(alone.pixels()[y0:y1, x0:x1], cell), ground
        rest = alone.img[outside][:, 1]
        if level is None:
            want = np.broadcast_to(pc.ramp_row(alone.img.shape[1])[None, :], alone.img.shape[:2])[outside]
            assert np.allclose(rest, want, rtol=1e-6) and np.ptp(np.log2(rest)) > 11.9, ground
        else:
            assert np.allclose(rest, pc.MID * 2.0 ** level, rtol=1e-6), ground
    assert [r["kind"] for r in charts["q-tone-ramp"].regions].count("ramp") == 4


def test_the_edge_chart_rides_its_gratings_on_the_bar(charts):
    chart = charts["q-edge"]
    bands = [r for r in chart.regions if r["kind"] == "bar grating"]
    assert [r["periodPx"] for r in bands] == pc.EDGE_PERIODS
    for r in bands:
        x0, y0, x1, y1 = r["box"]
        a, b = r["highColumns"]
        bar = np.full(x1 - x0, r["lowStops"])
        bar[a:b] = r["highStops"]
        x = np.arange(x0, x1)
        want = pc.MID * 2.0 ** (bar + r["amplitudeStops"] * np.sin(2 * np.pi * (x - r["x0"] + 0.5) / r["periodPx"]))
        assert np.allclose(region_pixels(chart, r)[(y1 - y0) // 2, :, 1], want, atol=CODE), r["periodPx"]
        assert r["highStops"] - r["lowStops"] == 3.0 and r["highStops"] + r["lowStops"] == 0.0
    plain = next(r for r in chart.regions if r["kind"] == "bar")
    assert plain["highColumns"] == bands[0]["highColumns"]


def test_round_2_jobs_ask_for_what_f1_and_the_brief_ask(plan):
    jobs_q = {job.name: job for job in plan.plan_q()}
    assert all(name.startswith("q-") for name in jobs_q) and not set(jobs_q) & {job.name for job in plan.plan()}
    for job in jobs_q.values():
        labels = [label for label, _ in job.items]
        assert labels[0] == "00_base" and len(labels) == len(set(labels)), job.name
    settings = lambda name: [s for _, s in jobs_q[name].items[1:]]
    assert settings("q-tone-four") == [{"Clarity2012": v} for v in ("-100", "-50", "50", "100")]
    for ground in ("dark", "bright", "ramp"):
        assert settings(f"q-tone-{ground}") == [{"Clarity2012": "100"}]
    assert settings("q-edge") == [{"Texture": "100"}, {"Clarity2012": "100"}]
    pair = {"Texture": "100", "Clarity2012": "100"}
    assert settings("q-combo") == [{"Texture": "100"}, {"Clarity2012": "100"}, pair]
    assert settings("q-raw") == [pair] and settings("q-grating-0") == [{"Texture": "100"}, {"Clarity2012": "100"}, pair]
    assert settings("q-raw-repeat") == [{}, {"Texture": "100"}, {"Clarity2012": "100"}]
    named = plan.by_name()
    for name in ("q-combo", "q-raw", "q-grating-0", "q-raw-repeat"):
        assert named[jobs_q[name].twin].source == jobs_q[name].source, name
    photos = [job for job in jobs_q.values() if job.kind == "photo"]
    assert len(photos) == 20 and sum(len(job.items) for job in photos) == 140
    for job in photos:
        assert [s for _, s in job.items] == [{}] + [{"Clarity2012": v} for v in ("-100", "-50", "50", "100")] + \
               [{"Texture": "-100"}, {"Texture": "100"}], job.name
    round1 = {(plan.CORPUS / path).resolve() for path, _ in plan.PHOTOS.values()}
    sources = [job.source.resolve() for job in photos]
    assert len(set(sources)) == 20 and not set(sources) & round1 and all(s.exists() for s in sources)
    scenes = [plan.SCENE_OF.get(s.stem, s.stem) for s in sources]
    round1_scenes = {plan.SCENE_OF.get(s.stem, s.stem) for s in round1}
    assert len(set(scenes)) == 20 and not set(scenes) & round1_scenes
    assert sum(job.bytes() for job in jobs_q.values()) < 40e9


def test_choose_takes_the_forced_frame_then_the_farthest_one_a_scene(plan):
    def row(name, median, scene=None):
        return {"path": f"/x/{name}.ARW", "scene": scene or name, "median": median, "spread": 3.0, "fine": 0.1, "coarse": 0.5}
    seeds = [row("seed", 0.0), row("seed-twin", 0.1, "taken scene")]
    rows = [row("near", 0.2), row("far", 4.0), row("far-twin", 3.9, "far"), row("mid", 2.0), row("old", -5.0, "taken scene")]
    order = [r["path"].split("/")[-1][:-4] for r in plan.choose(rows, seeds, 5)]
    assert order == ["far", "mid", "near"]
    order = plan.choose(rows, seeds, 2, forced=["near"])
    assert [r["path"].split("/")[-1][:-4] for r in order] == ["near", "far"] and order[0]["distance"] is None


def test_scene_measures_read_level_spread_and_detail():
    import presence_plan
    flat = np.full((64, 96, 3), pc.MID * 2.0 ** 1.5, np.float32)
    m = presence_plan.scene_measures(flat)
    assert m["median"] == pytest.approx(1.5, abs=1e-3) and m["spread"] == pytest.approx(0, abs=1e-3)
    assert m["fine"] == pytest.approx(0, abs=1e-6) and m["coarse"] == pytest.approx(0, abs=1e-6)
    ramp = pc.MID * 2.0 ** np.linspace(-4, 4, 4001)[None, :, None] * np.ones((4, 1, 3))
    m = presence_plan.scene_measures(ramp)
    assert m["median"] == pytest.approx(0, abs=0.01) and m["spread"] == pytest.approx(6.4, abs=0.01)
    stripes = flat * 2.0 ** (0.3 * (np.arange(96) % 2 * 2 - 1))[None, :, None]
    bars = flat * 2.0 ** (0.3 * (np.arange(96) // 48 * 2 - 1))[None, :, None]
    fine, coarse = presence_plan.scene_measures(stripes), presence_plan.scene_measures(bars)
    assert fine["fine"] > 0.2 > fine["coarse"] and coarse["coarse"] > 0.1 > coarse["fine"]


def test_sanity_checks_direction_alone_where_there_is_no_50_and_pairs_each_control(plan):
    job = plan.Job("q-x", Path("x.ARW"), "photo", (), "", controls=("texture", "clarity"))
    def e(fine, local, **settings):
        return {"stats": {"fine": fine, "local": local}, "settings": settings}
    entries = {"00_base": e(0.2, 0.8), "clarity_-100": e(0.2, 0.6), "clarity_-50": e(0.2, 0.7),
               "clarity_+50": e(0.2, 0.9), "clarity_+100": e(0.2, 1.0), "texture_-100": e(0.1, 0.8),
               "texture_+100": e(0.15, 0.8)}
    rows = {r["control"]: r["verdict"] for r in plan.sanity(job, entries)}
    assert rows["clarity"] == "ok"
    assert rows["texture"].startswith("check: +100 moves fine the wrong way")
    entries["texture_+100"] = e(0.3, 0.8)
    assert {r["control"]: r["verdict"] for r in plan.sanity(job, entries)}["texture"] == \
           "ok (direction only at +100, -100: one value of that sign)"
    entries["pair"] = e(0.3, 0.7, Texture="100", Clarity2012="100")
    (pair,) = plan.pairs(job, entries)
    assert pair["verdict"] == "check: local moves the wrong way for clarity"
    entries["pair"] = e(0.3, 1.1, Texture="100", Clarity2012="100")
    assert plan.pairs(job, entries)[0]["verdict"] == "ok"


# MARK: Round 3

def test_the_white_patch_is_brighter_than_the_haze_and_the_rest_is_p_haze_neutral(charts):
    white, neutral = charts["r-haze-white"], charts["p-haze-neutral"]
    x0, y0, x1, y1 = pc.WHITE_BOX
    assert np.allclose(region_pixels(white, white.regions[-1]), pc.WHITE_VALUE, atol=CODE)
    outside = np.ones(white.img.shape[:2], bool)
    outside[y0:y1, x0:x1] = False
    assert np.array_equal(white.pixels()[outside], neutral.pixels()[outside])
    around = neutral.img[y0:y1, x0:x1]
    assert pc.WHITE_VALUE > max(pc.AIRLIGHT["neutral"]) and pc.WHITE_VALUE > around.max()
    assert x1 > 0.9 * pc.HAZE_SIZE[0], "the haziest strip is at the right"


def test_round_3_jobs_ask_for_what_f2_f3_and_the_brief_ask(plan):
    jobs_r = {job.name: job for job in plan.plan_r()}
    earlier = {job.name for job in plan.plan() + plan.plan_q()}
    assert all(name.startswith("r-") for name in jobs_r) and not set(jobs_r) & earlier
    for job in jobs_r.values():
        labels = [label for label, _ in job.items]
        assert labels[0] == "00_base" and len(labels) == len(set(labels)), job.name
    settings = lambda name: [s for _, s in jobs_r[name].items]
    assert settings("r-haze-neutral")[:2] == [{}, {}]
    assert {s["Dehaze"] for s in settings("r-haze-neutral")[2:]} >= {"-75", "-10", "10", "75"}
    for name, crop, size in (("r-haze-neutral-crop", plan.LEFT_THIRD, (1600, 3200)),
                             ("r-haze-two-crop", plan.BOTTOM_HALF, (4800, 1600))):
        assert all(s.items() >= crop.items() for s in settings(name)) and jobs_r[name].size == size
        assert settings(name)[1]["Dehaze"] == "100"
        width, height = pc.HAZE_SIZE
        assert round(width * (float(crop["CropRight"]) - float(crop["CropLeft"]))) == size[0]
        assert round(height * (float(crop["CropBottom"]) - float(crop["CropTop"]))) == size[1]
    flags = [s.get("HasCrop") for name in jobs_r if name.startswith("r-crop-flag-") for s in settings(name)]
    assert flags == ["true", "1", None]
    assert jobs_r["r-sky-standard"].source == plan.by_name()["p-photo-sky"].source
    assert jobs_r["r-sky-matrix"].source.name == "r-sky-matrix.dng" and settings("r-sky-matrix") == settings("r-sky-standard")
    grid = settings("r-colour-grid")
    for pair in ({"Exposure2012": e, k: v} for e in ("1", "-1") for k, v in (("Saturation", "50"), ("Vibrance", "100"),
                                                                             ("Vibrance", "-100"))):
        assert pair in grid and all({k: v} in grid for k, v in pair.items()), pair
    assert {s.get("Vibrance") for s in settings("r-colour-grid-tif")} >= {"10", "75", "-10", "-75"}
    assert jobs_r["r-colour-grid-tif"].source.suffix == ".tif"
    photos = [job for name, job in jobs_r.items() if name.startswith("r-photo-")]
    round2 = {job.name: job for job in plan.plan_q() if job.kind == "photo"}
    assert len(photos) == 20 and sum(len(job.items) for job in photos) == 180
    for job in photos:
        assert [s for _, s in job.items] == [{}, {"Dehaze": "-100"}, {"Dehaze": "50"}, {"Dehaze": "100"},
                                             {"Vibrance": "-100"}, {"Vibrance": "50"}, {"Vibrance": "100"},
                                             {"Saturation": "-100"}, {"Saturation": "100"}], job.name
        assert round2[job.twin].source == job.source
    again = [name for name in jobs_r if name.startswith("r-again-")]
    assert len(again) == 5
    for name in ["r-end-haze-neutral", "r-end-photo-horizon"] + again:
        assert jobs_r[jobs_r[name].twin].source == jobs_r[name].source
    for name in again:
        asked = [tuple(s.items()) for s in settings(name)[1:]]
        twin = [tuple(s.items()) for s in settings(jobs_r[name].twin)]
        assert all(asked.count(a) == 2 and a in twin for a in asked), name
    assert sum(job.bytes() for job in jobs_r.values()) < 45e9


def test_write_takes_patterns_and_skips_a_job_already_run(plan, jobs_folder, tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(plan, "DATA", tmp_path)
    monkeypatch.setattr(plan.jobs, "clone", lambda source, target: target)
    (jobs_folder / "r-end-haze-neutral.done").write_text("DONE\t1\n")
    plan.write(["r-end-*"])
    assert (jobs_folder / "r-end-photo-horizon.job").exists() and not (jobs_folder / "r-end-haze-neutral.job").exists()
    assert "r-end-haze-neutral: already written or run, skipped" in capsys.readouterr().out


def test_an_asked_setting_matches_what_lightroom_writes_back(plan):
    assert plan.same("0.333333", "0.333333") and plan.same("0.3333333", "0.333333") and plan.same("100", "+100")
    assert plan.same("true", "True") and not plan.same("true", "False") and not plan.same("0.33", "0.333333")
    assert plan.same("1", "True") and plan.same("0", "False") and not plan.same("1", "False")
    assert not plan.same("1", None) and not plan.same("Adobe Standard", "Adobe Neutral")


def test_the_manifest_flags_an_export_whose_crop_did_not_take(plan, tmp_path, monkeypatch):
    monkeypatch.setattr(plan, "DATA", tmp_path)
    job = plan.Job("r-x", Path("x.dng"), "chart", (("00_base", {}), ("dehaze_+100", {"Dehaze": "100"})), "",
                   size=(4, 8))
    crop = 'crs:HasCrop="True" crs:CropLeft="0" crs:CropRight="0.333333" crs:ProcessVersion="15.4"'
    asked = {job.stem(label): ("in", {"HasCrop": "true", "CropRight": "0.3333333", **s}) for label, s in job.items}
    (tmp_path / "exports-r-x").mkdir()
    export(job.export("00_base"), np.full((8, 4, 3), 0.2), f'<x {crop}/>')
    export(job.export("dehaze_+100"), np.full((8, 12, 3), 0.2), '<x crs:HasCrop="False" crs:Dehaze="+100"/>')
    base, lab = plan.read_export(job, "00_base", asked)
    assert "problem" not in base and base["applied"]["CropRight"] == "0.333333"
    wide, _ = plan.read_export(job, "dehaze_+100", asked, lab)
    assert "HasCrop asked true, applied False" in wide["problem"] and "size 12 x 8, expected 4 x 8" in wide["problem"]


def test_sanity_checks_every_value_and_the_order_of_their_effects(plan):
    job = plan.Job("r-x", Path("x.dng"), "chart", (), "", controls=("dehaze",))
    dark = {"00_base": 40, "dehaze_-75": 50, "dehaze_-10": 41, "dehaze_+10": 39, "dehaze_+50": 36, "dehaze_+75": 37}
    entries = {label: {"stats": {"dark": v}} for label, v in dark.items()}
    (row,) = plan.sanity(job, entries)
    assert row["verdict"] == "check: +75 does not move dark more than +50"
    entries["dehaze_+75"] = {"stats": {"dark": 33}}
    entries["dehaze_-10"] = {"stats": {"dark": 39.5}}
    assert plan.sanity(job, entries)[0]["verdict"] == "check: -10 moves dark the wrong way"
    del entries["dehaze_-10"]
    assert plan.sanity(job, entries)[0]["verdict"] == "ok (direction only at -75: one value of that sign)"


def test_a_presence_control_beside_exposure_is_judged_against_that_exposure_alone(plan):
    job = plan.Job("r-x", Path("x.dng"), "chart", (), "")
    e = lambda chroma, **s: {"stats": {"chroma": chroma}, "settings": s}
    entries = {"00_base": e(20), "saturation_+50": e(30, Saturation="50"), "ex+1": e(15, Exposure2012="1"),
               "ex+1_sat+50": e(18, Exposure2012="1", Saturation="50"), "ex-1_vib-100": e(10, Exposure2012="-1", Vibrance="-100")}
    rows = {r["label"]: r for r in plan.pairs(job, entries)}
    assert set(rows) == {"ex+1_sat+50", "ex-1_vib-100"}
    assert rows["ex+1_sat+50"]["against"] == "ex+1" and rows["ex+1_sat+50"]["verdict"] == "ok"
    assert rows["ex+1_sat+50"]["change"] == {"saturation +50: chroma": 3}
    assert rows["ex-1_vib-100"]["verdict"] == "check: no render without its Presence controls"


def test_difference_counts_codes(plan, tmp_path):
    rng = np.random.default_rng(5)
    img = rng.uniform(0.05, 0.9, (16, 8, 3))
    a, b = export(tmp_path / "a.tif", img), export(tmp_path / "b.tif", img)
    assert plan.difference(a, b) == {"identical": True, "codesDiffer": 0.0, "max": 0, "mean": 0.0}
    encoded = np.round(img ** (256 / 461) * 65535)
    encoded[0, 0, 0] += 7
    c = export(tmp_path / "c.tif", (encoded / 65535) ** (461 / 256))
    d = plan.difference(a, c, rows=3)
    assert d["identical"] is False and d["max"] == 7 and d["codesDiffer"] == pytest.approx(1 / img.size, abs=1e-5)
    assert plan.difference(a, export(tmp_path / "d.tif", img[:8])) is None


def test_every_render_is_compared_with_the_same_settings_in_its_twin_and_in_its_own_job(plan, tmp_path, monkeypatch):
    monkeypatch.setattr(plan, "DATA", tmp_path)
    img = np.random.default_rng(9).uniform(0.05, 0.9, (8, 8, 3))
    first = plan.Job("r-a", Path("x.dng"), "chart", (("00_base", {}), ("dehaze_+50", {"Dehaze": "50"})), "")
    again = plan.Job("r-b", Path("x.dng"), "chart", (("00_base", {}), ("dehaze_+50", {"Dehaze": "50"}),
                                                     ("again_dehaze_+50", {"Dehaze": "50"})), "", twin="r-a")
    for job, label, picture in ((first, "00_base", img), (first, "dehaze_+50", img * 0.9), (again, "00_base", img),
                                (again, "dehaze_+50", img * 0.9), (again, "again_dehaze_+50", img * 0.8)):
        job.export(label).parent.mkdir(exist_ok=True)
        export(job.export(label), picture)
    entries = {label: {"pixels": label} for label, _ in again.items}
    twin = plan.twin_check(again, first, entries, True)
    assert twin["identical"] and twin["sameRound"] and twin["renders"]["dehaze_+50"]["identical"]
    assert twin["renders"]["again_dehaze_+50"]["of"] == "dehaze_+50" and not twin["renders"]["again_dehaze_+50"]["identical"]
    assert plan.sameness(twin["renders"]["again_dehaze_+50"]).startswith("**differs**, 100.0% of codes")
