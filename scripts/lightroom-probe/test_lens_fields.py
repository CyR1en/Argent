"""Synthetic lens-chart coverage and defringe measurements; no Lightroom or owner data."""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lens-correction"))
import lightroom_fields as fields  # noqa: E402
import make_lens_charts as charts  # noqa: E402


@pytest.mark.parametrize("fringe_width", [4, 6])
def test_fringe_layout_covers_hue_wheel_and_original_width_controls(fringe_width):
    image, layout = charts.fringe(800, 600, fringe_width)
    layout = json.loads(json.dumps(layout))
    fringes = [r for r in layout["regions"] if r["kind"] == "fringe"]
    assert {r["hue_degrees"] for r in fringes if r["fringe_width_px"] == fringe_width} == set(range(0, 360, 10))
    occupied = np.zeros(image.shape[:2], dtype=bool)
    zero = np.array([1, -2, 1]) / np.sqrt(6)
    quarter = np.array([1, 0, -1]) / np.sqrt(2)
    for region in layout["regions"]:
        offset = np.array(region["rgb_offset"])
        projected = offset - offset.mean()
        angle = np.rad2deg(np.arctan2(projected @ quarter, projected @ zero)) % 360
        assert angle == pytest.approx(region["hue_degrees"], abs=1e-10)
        assert np.linalg.norm(projected) == pytest.approx(0.12 * np.sqrt(8 / 3))
        level = 0.65 if region["kind"] == "fringe" else 0.4
        x0, y0, x1, y1 = region["box"]
        assert np.allclose(image[y0:y1, x0:x1], level + offset, atol=1e-7)
        boxes = [region["box"]]
        if region["kind"] == "fringe":
            assert x1 - x0 == region["fringe_width_px"]
            rx0, ry0, rx1, ry1 = region["reference"]
            assert np.all(image[ry0:ry1, rx0:rx1] == np.float32(0.65))
            boxes.append(region["reference"])
            # The side facing the bar is dark; the fringe itself is bright.
            assert (np.all(image[y0:y1, x0 - 1] == np.float32(0.06)) or
                    np.all(image[y0:y1, x1] == np.float32(0.06)))
        for x0, y0, x1, y1 in boxes:
            assert 0 <= x0 < x1 <= layout["width"] and 0 <= y0 < y1 <= layout["height"]
            assert not occupied[y0:y1, x0:x1].any()
            occupied[y0:y1, x0:x1] = True
    for colour, hue, sign in [("purple", 0, 1), ("green", 180, -1)]:
        for size in (2, 6, 12):
            group = [r for r in layout["regions"] if r["colour"] == colour and r["fringe_width_px"] == size]
            assert sorted(r["kind"] for r in group) == ["fringe", "fringe", "protected"]
            for region in group:
                assert region["hue_degrees"] == hue
                assert np.array_equal(region["rgb_offset"], sign * 0.12 * np.array([1, -1, 1]))


def test_fringe_rejects_cells_or_chroma_that_cannot_hold_the_stimuli():
    with pytest.raises(ValueError, match="too small"):
        charts.fringe(400, 300)
    with pytest.raises(ValueError, match="reduce --chroma"):
        charts.fringe(800, 600, chroma=0.3)


def test_defringe_reports_hue_width_and_changes_for_every_region():
    before, layout = charts.fringe(800, 600)
    after = before.copy()
    # A fixed chroma reduction leaves the neutral component unchanged.
    for region in layout["regions"]:
        x0, y0, x1, y1 = region["box"]
        patch = before[y0:y1, x0:x1]
        neutral = patch.mean(axis=-1, keepdims=True)
        after[y0:y1, x0:x1] = neutral + 0.5 * (patch - neutral)
    rows = fields.defringe(before, after, layout)
    assert len(rows) == len(layout["regions"])
    for region, row in zip(layout["regions"], rows):
        assert all(row[key] == value for key, value in region.items())
        assert row["chroma_removed"] == pytest.approx(row["chroma_before"] / 2, abs=1e-6)
        if region["kind"] == "fringe":
            assert row["excess_chroma_removed"] == pytest.approx(row["chroma_removed"], abs=1e-6)
        else:
            assert row["chroma_change"] == pytest.approx(-row["chroma_removed"])


def test_synthetic_tiff_measurements_recover_hue_interval_and_width_limit(capsys):
    pytest.importorskip("scipy")  # the self-test's registration and fits need SciPy
    fields.self_test()
    assert "PASS defringe selectivity" in capsys.readouterr().out


def test_neutral_fringe_adds_every_two_degree_boundary_stimulus():
    image, layout = charts.fringe(800, 600, dense=True)
    fringes = [r for r in layout["regions"] if r["kind"] == "fringe"]
    for start in (276, 56, 164, 206):
        for hue in range(start, start + 25, 2):
            strips = [r for r in fringes if r["hue_degrees"] == hue and r["fringe_width_px"] == 6]
            assert len(strips) == 2
            for r in strips:
                x0, y0, x1, y1 = r["box"]
                assert x1 - x0 == 6 and 0 <= y0 < y1 <= image.shape[0]


def test_protected_median_does_not_hide_a_destroyed_rim():
    before, layout = charts.fringe(800, 600)
    after = before.copy()
    r = next(r for r in layout["regions"] if r["kind"] == "protected")
    x0, y0, x1, y1 = r["box"]
    patch = after[y0:y1, x0:x0+2]
    patch[:] = patch.mean(axis=-1, keepdims=True)
    measured = fields.defringe(before, after, layout)[layout["regions"].index(r)]
    assert measured["rgb_change_norm"] == 0
    assert measured["pixels_losing_half_chroma"] == pytest.approx(2 / (x1-x0))


def test_amount_discovery_skips_a_newer_reverted_sweep(tmp_path, monkeypatch):
    amounts = (0, 50, 100, 150, 200)
    for name in ('lc3r3-05-amounts-grid-explicit', 'lc3r4-05-amounts-grid'):
        folder = tmp_path / ('exports-' + name)
        folder.mkdir()
        for a in amounts:
            (folder / f'{name}_distortion-{a:03}.tif').touch()

    def accepted(path):
        amount = path.stem.rsplit('-', 1)[1]
        return {'crs:LensProfileSetup': ['Custom'], 'crs:LensProfileDistortionScale':
                [str(int(amount)) if 'explicit' in path.parent.name else '100']}

    monkeypatch.setattr(fields, 'xmp', accepted)
    paths = fields.accepted_sweep(tmp_path, 'grid', 'distortion')
    assert all('lc3r3' in p.parent.name for p in paths)
    assert [int(p.stem.rsplit('-', 1)[1]) for p in paths] == list(amounts)
    paths[-1].unlink()
    with pytest.raises(ValueError, match='no accepted Custom'):
        fields.accepted_sweep(tmp_path, 'grid', 'distortion')
