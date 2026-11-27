import ctypes
import errno
import hashlib
import json
import time
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from argent_bake import __version__, bake, synthetic
from argent_bake.__main__ import main
from argent_bake.bake import bake_stock, paper_named
from argent_bake.cube import read_binary, read_cube
from argent_bake.encoding import LogEncoding
from argent_bake.negative import MID_GRAY, dye_amounts
from argent_bake.printing import Printer
from tests.conftest import STOCKS

profile = synthetic.profile()


def lut_array(path, size):
    found, rows = read_cube(str(path))
    assert found == size
    return np.array(rows).reshape(size, size, size, 3)


def trilinear(lut, coordinates):
    """Sample a [b][g][r] LUT at (n, 3) coordinates in 0...1, given as (r, g, b)."""
    size = lut.shape[0]
    p = np.clip(coordinates, 0, 1) * (size - 1)
    i0 = np.minimum(p.astype(int), size - 2)
    f = p - i0
    out = np.zeros((len(p), 3))
    for corner in range(8):
        offset = np.array([(corner >> 0) & 1, (corner >> 1) & 1, (corner >> 2) & 1])
        weight = np.prod(np.where(offset == 1, f, 1 - f), axis=1)
        index = i0 + offset
        out += weight[:, None] * lut[index[:, 2], index[:, 1], index[:, 0]]
    return out


@pytest.fixture(scope="module")
def baked(tmp_path_factory):
    out = tmp_path_factory.mktemp("stock")
    result = bake_stock(profile, synthetic.paper(), out, size=33)
    return out, result


@pytest.fixture(scope="module")
def baked_portra(tmp_path_factory, stocks, endura):
    out = tmp_path_factory.mktemp("portra")
    started = time.perf_counter()
    result = bake_stock(stocks["portra400"], endura, out, size=65)
    return out, result, time.perf_counter() - started


def test_writes_the_folder_the_app_loads(baked):
    out, result = baked
    assert sorted(p.name for p in out.iterdir()) == ["negative.cube", "negative.lut3d", "print.cube", "print.lut3d", "stock.json"]
    manifest = json.loads((out / "stock.json").read_text())
    assert manifest["schema"] == 2
    assert manifest["id"] == "synthetic-v0" and manifest["status"] == "synthetic"
    assert manifest["displayName"] == "Synthetic" and manifest["modelledFilm"] is None
    assert manifest["boxSpeed"] == 400
    assert manifest["densityRange"] == result.density_range and manifest["densityRange"] % 0.5 == 0
    assert manifest["negative"] == {
        "file": "negative.cube", "binary": "negative.lut3d", "size": 33,
        "logEncoding": {"stopsBelowMidGray": 8.0, "stopsAboveMidGray": 5.0, "midGray": 0.18}}
    assert manifest["print"]["file"] == "print.cube" and manifest["print"]["binary"] == "print.lut3d"
    assert manifest["print"]["size"] == 33
    assert manifest["print"]["exposurePerUnit"] == pytest.approx(result.exposure_per_unit, abs=1e-6)
    assert len(manifest["print"]["exposurePerUnit"]) == 3 and min(manifest["print"]["exposurePerUnit"]) > 0
    bake = manifest["bake"]
    assert bake["tool"] == "argent-bake" and bake["version"] == __version__ == "0.5.0"
    assert bake["paper"] == "synthetic-print-v0"
    assert len(bake["daylightFiltration"]) == 3
    assert bake["midGrayLogExposure"] == pytest.approx(-1.5417, abs=0.001)
    assert {"grayCardRedDensity", "iso5800Speed", "negativeModel"} <= set(bake)
    assert {"method", "rms", "maxError", "crossTalk", "parameters"} <= set(bake["negativeModel"])


def test_both_cubes_parse_and_stay_in_range(baked):
    out, _ = baked
    negative, print_lut = lut_array(out / "negative.cube", 33), lut_array(out / "print.cube", 33)
    assert 0 < negative.min() and negative.max() <= 1
    assert print_lut.min() >= 0 and np.all(np.isfinite(print_lut))


def test_the_binary_files_describe_the_same_tables_as_the_cubes(baked):
    out, _ = baked
    for stem in ("negative", "print"):
        size, rows = read_cube(str(out / f"{stem}.cube"))
        binary_size, binary_rows = read_binary(str(out / f"{stem}.lut3d"))
        assert binary_size == size == 33 and len(binary_rows) == len(rows)
        assert np.abs(np.array(binary_rows) - np.array(rows)).max() < 1e-6
    data = (out / "negative.lut3d").read_bytes()
    assert data[:8] == b"ARGLUT3D" and len(data) == 16 + 4 * 3 * 33 ** 3


def test_mid_gray_prints_as_a_neutral_gray_through_the_written_files(baked):
    # The contract the Swift tests check from the other side.
    out, result = baked
    encoding = LogEncoding()
    mid = np.full((1, 3), encoding.encode(MID_GRAY))
    a = trilinear(lut_array(out / "negative.cube", 33), mid)
    printed = trilinear(lut_array(out / "print.cube", 33), a)[0]
    assert printed == pytest.approx(np.full(3, 0.18), abs=0.01)


def test_the_luts_agree_with_direct_evaluation(baked):
    out, result = baked
    negative, print_lut = lut_array(out / "negative.cube", 33), lut_array(out / "print.cube", 33)
    rng = np.random.default_rng(7)
    encoded = rng.uniform(0.0, 1.0, size=(400, 3))
    scene = LogEncoding().decode(encoded)

    printer = Printer(synthetic.paper(), profile.dyes, profile.base)
    direct = np.maximum(printer(dye_amounts(profile, scene), result.filtration), 0.0)
    through = trilinear(print_lut, trilinear(negative, encoded))

    def srgb(c):
        return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.maximum(c, 0) ** (1 / 2.4) - 0.055)

    # Trilinear here, tetrahedral in the app. With 13 stops across 33 nodes the trilinear error
    # reaches 3.5/255 (measured); at the 65 nodes the app bakes it is under 1/255.
    assert np.abs(srgb(through) - srgb(direct)).max() < 4 / 255


def test_baking_twice_gives_identical_files(tmp_path):
    digests = []
    for name in ("a", "b"):
        out = tmp_path / name
        bake_stock(profile, synthetic.paper(), out, size=9)
        digests.append({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir())})
    assert digests[0] == digests[1]


@pytest.mark.parametrize("filename", ["negative.cube", "negative.lut3d", "print.cube", "print.lut3d", "stock.json"])
def test_rebake_preserves_the_old_stock_if_a_write_fails(tmp_path, monkeypatch, filename):
    out = tmp_path / "stock"
    paper = synthetic.paper()
    bake_stock(profile, paper, out, size=5)
    old_files = {p.name: p.read_bytes() for p in out.iterdir()}

    def fail_after_write(write):
        def wrapped(path, *args, **kwargs):
            result = write(path, *args, **kwargs)
            if Path(path).name == filename:
                raise OSError(f"injected failure after writing {filename}")
            return result
        return wrapped

    monkeypatch.setattr(bake, "write_cube", fail_after_write(bake.write_cube))
    monkeypatch.setattr(bake, "write_binary", fail_after_write(bake.write_binary))
    monkeypatch.setattr(Path, "write_text", fail_after_write(Path.write_text))

    with pytest.raises(OSError, match="injected failure"):
        bake_stock(profile, paper, out, size=7)

    assert {p.name: p.read_bytes() for p in out.iterdir()} == old_files
    assert list(tmp_path.iterdir()) == [out]


@pytest.mark.parametrize("error", [errno.ENOSYS, errno.EINVAL])
def test_rebake_preserves_the_old_stock_if_exchange_fails(tmp_path, monkeypatch, error):
    out = tmp_path / "stock"
    paper = synthetic.paper()
    bake_stock(profile, paper, out, size=5)
    old_files = {p.name: p.read_bytes() for p in out.iterdir()}

    def fail_exchange(*args):
        ctypes.set_errno(error)
        return -1

    libc = SimpleNamespace(renameat2=fail_exchange, renamex_np=fail_exchange)
    monkeypatch.setattr(ctypes, "CDLL", lambda *args, **kwargs: libc)
    with pytest.raises(OSError) as exc:
        bake_stock(profile, paper, out, size=7)

    assert exc.value.errno == error
    assert {p.name: p.read_bytes() for p in out.iterdir()} == old_files
    assert list(tmp_path.iterdir()) == [out]


def test_rebake_replaces_the_stock_and_keeps_unrelated_entries(tmp_path, monkeypatch):
    out = tmp_path / "stock"
    expected = tmp_path / "expected"
    paper = synthetic.paper()
    bake_stock(profile, paper, out, size=5)
    bake_stock(profile, paper, expected, size=7)
    (out / "notes").mkdir()
    (out / "notes" / "stock.json").write_text("unrelated")
    (out / "info").symlink_to("notes/stock.json")

    rename = Path.rename

    def rename_without_a_gap(path, target):
        assert out.is_dir()
        result = rename(path, target)
        assert out.is_dir()
        return result

    monkeypatch.setattr(Path, "rename", rename_without_a_gap)
    exchange = bake._exchange_directories

    def exchange_without_a_gap(staging, target):
        assert target == out and out.is_dir()
        exchange(staging, target)
        assert out.is_dir()

    monkeypatch.setattr(bake, "_exchange_directories", exchange_without_a_gap)
    result = bake_stock(profile, paper, out, size=7)

    assert result.directory == out
    assert {p.name: p.read_bytes() for p in expected.iterdir()} == {
        p.name: (out / p.name).read_bytes() for p in expected.iterdir()
    }
    assert (out / "notes" / "stock.json").read_text() == "unrelated"
    assert (out / "info").readlink() == Path("notes/stock.json")
    assert set(tmp_path.iterdir()) == {out, expected}


@pytest.mark.parametrize("out_arg", [".", ".."], ids=["cwd", "ancestor"])
def test_rebake_refuses_an_output_containing_the_working_directory(tmp_path, monkeypatch, out_arg):
    out = tmp_path / "stock"
    paper = synthetic.paper()
    bake_stock(profile, paper, out, size=5)
    cwd = out if out_arg == "." else out / "work"
    cwd.mkdir(exist_ok=True)

    def snapshot():
        return {p.relative_to(tmp_path): p.read_bytes() if p.is_file() else None for p in tmp_path.rglob("*")}

    old_entries = snapshot()
    monkeypatch.chdir(cwd)

    def unexpected_bake(*args):
        pytest.fail("invalid output must be rejected before baking")

    monkeypatch.setattr(bake, "bake_negative", unexpected_bake)
    with pytest.raises(ValueError, match="it is the current working directory or contains it"):
        bake_stock(profile, paper, out_arg, size=7)

    assert snapshot() == old_entries


def test_a_profile_for_another_paper_is_refused(tmp_path):
    other = synthetic.paper().__class__(**{**synthetic.paper().__dict__, "name": "someone-elses-paper"})
    with pytest.raises(ValueError, match="prints onto"):
        bake_stock(profile, other, tmp_path, size=9)


def test_paper_lookup():
    assert paper_named("synthetic-print-v0").name == "synthetic-print-v0"
    assert paper_named("kodak-endura-premier").name == "kodak-endura-premier"
    with pytest.raises(ValueError, match="no print paper named"):
        paper_named("shared-print-model-v1")


class TestPortra400:
    def test_a_full_bake_finishes_in_time_and_lands_on_the_pinned_numbers(self, baked_portra):
        out, result, seconds = baked_portra
        assert seconds < 60.0
        assert result.density_range == 2.5
        assert result.exposure_per_unit == pytest.approx([0.843, 0.850, 0.812], abs=0.002)
        manifest = json.loads((out / "stock.json").read_text())
        assert manifest["schema"] == 2 and manifest["id"] == "kodak-portra-400" and manifest["status"] == "datasheet"
        # The name the app shows, and the film it models for the descriptive line.
        assert manifest["displayName"] == "Portra 400" and manifest["modelledFilm"] == "Kodak Portra 400"
        assert manifest["densityRange"] == result.density_range
        assert manifest["print"]["exposurePerUnit"] == pytest.approx(result.exposure_per_unit, abs=1e-6)
        assert manifest["negative"]["logEncoding"] == {
            "stopsBelowMidGray": 8.0, "stopsAboveMidGray": 8.0, "midGray": MID_GRAY,
        }
        assert manifest["bake"]["highlightShoulder"] == {"startStops": 3.0, "widthStops": 2.5}
        assert manifest["bake"]["midGrayLogExposure"] == pytest.approx(-1.5418, abs=0.001)
        assert manifest["bake"]["grayCardRedDensity"] == pytest.approx(0.835, abs=0.01)
        assert manifest["bake"]["iso5800Speed"] == pytest.approx(398, abs=1)
        model = manifest["bake"]["negativeModel"]
        assert model["rms"] < 0.010 and np.asarray(model["crossTalk"]).shape == (3, 3) and "cyan" in model["parameters"]

    def test_the_manifest_carries_grain_and_halation(self, baked_portra):
        out = baked_portra[0]
        manifest = json.loads((out / "stock.json").read_text())
        assert len(manifest["grain"]["amounts"]) == len(manifest["grain"]["sigma48"]) > 40
        assert manifest["halation"] == {"strength": 0.015, "greenShare": 0.25, "radiusMicrometres": 180.0}

    def test_mid_gray_prints_neutral_and_the_luts_are_in_range(self, baked_portra):
        out, result, _ = baked_portra
        negative, print_lut = lut_array(out / "negative.cube", 65), lut_array(out / "print.cube", 65)
        assert 0 < negative.min() and negative.max() <= 1 and print_lut.min() >= 0
        mid = np.full((1, 3), LogEncoding(stops_above_mid_gray=8).encode(MID_GRAY))
        printed = trilinear(print_lut, trilinear(negative, mid))[0]
        assert printed == pytest.approx(np.full(3, 0.18), abs=0.01)
        # The plotted cyan top leaves room for positive print offsets beyond all baked inputs.
        assert negative.max() * result.density_range < 2.437 < result.density_range

    def test_the_baked_print_keeps_highlight_separation_past_the_old_ceiling(self, baked_portra):
        out, _, _ = baked_portra
        negative, print_lut = lut_array(out / "negative.cube", 65), lut_array(out / "print.cube", 65)
        encoding = LogEncoding(stops_above_mid_gray=8)
        coords = np.repeat([[encoding.encode(MID_GRAY * 2.0 ** ev)] for ev in range(3, 9)], 3, axis=1)
        printed = trilinear(print_lut, trilinear(negative, coords))
        gaps = np.diff(printed @ [0.2627, 0.6780, 0.0593])
        assert np.all(gaps > 0.001)
        assert np.all(np.diff(gaps) < 0)

    def test_the_binary_files_match(self, baked_portra):
        out, _, _ = baked_portra
        for stem in ("negative", "print"):
            size, rows = read_cube(str(out / f"{stem}.cube"))
            binary_size, binary_rows = read_binary(str(out / f"{stem}.lut3d"))
            assert binary_size == size == 65
            assert np.abs(np.array(binary_rows) - np.array(rows)).max() < 1e-6


class TestCommandLine:
    @pytest.mark.parametrize("document", [
        pytest.param(b"[]", id="array"),
        pytest.param(b"null", id="null"),
        pytest.param(b"\xff\xfe{", id="invalid-utf8"),
        pytest.param(b"{", id="malformed-json"),
        pytest.param(None, id="valid-object"),
    ])
    def test_check_reports_invalid_profile_documents(self, tmp_path, capsys, document):
        path = tmp_path / "profile.json"
        path.write_bytes(document if document is not None else json.dumps(synthetic.profile_dict()).encode())

        assert main(["check", "--profile", str(path)]) == (0 if document is None else 2)

        captured = capsys.readouterr()
        assert "Traceback" not in captured.out + captured.err
        if document is None:
            assert captured.err == ""
            assert "all negative gates pass" in captured.out
        else:
            assert captured.out == ""
            assert len(captured.err.splitlines()) == 1
            assert captured.err.startswith(f"error: cannot read profile {path}:")

    @pytest.mark.parametrize("stock_id", [["synthetic-v0"], 7, None], ids=["array", "integer", "null"])
    @pytest.mark.parametrize("command", ["check", "bake"])
    def test_invalid_primary_stock_id_fails_cleanly(self, tmp_path, capsys, stock_id, command):
        path = tmp_path / "invalid.json"
        path.write_text(json.dumps(dict(synthetic.profile_dict(), id=stock_id)))
        out = tmp_path / "baked"
        args = [command, "--profile", str(path)]
        if command == "bake":
            args += ["--size", "2", "--out", str(out)]

        assert main(args) == 2

        captured = capsys.readouterr()
        assert captured.out == ""
        assert len(captured.err.splitlines()) == 1
        assert captured.err.startswith(f"error: profile {path}: id must be")
        assert not (out / "stock.json").exists()

    @pytest.mark.parametrize("document", [b"[]", b"null", b"\xff\xfe{", b"{"])
    def test_bake_all_continues_after_invalid_profile_document(self, tmp_path, capsys, monkeypatch, document):
        import argent_bake.__main__ as cli

        stocks = tmp_path / "stocks"
        stocks.mkdir()
        invalid = stocks / "a-invalid.json"
        invalid.write_bytes(document)
        (stocks / "z-valid.json").write_text(json.dumps(synthetic.profile_dict()))
        monkeypatch.setattr(cli, "STOCKS_DIR", stocks)
        out = tmp_path / "baked"

        assert main(["bake", "--all", "--size", "5", "--out", str(out)]) == 2

        captured = capsys.readouterr()
        assert "Traceback" not in captured.out + captured.err
        assert len(captured.err.splitlines()) == 1
        assert captured.err.startswith(f"error: cannot read profile {invalid}:")
        assert "wrote" in captured.out
        assert (out / "synthetic-v0" / "stock.json").is_file()
        assert (out / "synthetic-v0" / "print.lut3d").is_file()

    def test_bake_all_continues_after_invalid_primary_stock_id(self, tmp_path, capsys, monkeypatch):
        import argent_bake.__main__ as cli

        stocks = tmp_path / "stocks"
        stocks.mkdir()
        invalid = stocks / "a-invalid.json"
        invalid.write_text(json.dumps(dict(synthetic.profile_dict(), id=["synthetic-v0"])))
        (stocks / "z-valid.json").write_text(json.dumps(synthetic.profile_dict()))
        monkeypatch.setattr(cli, "STOCKS_DIR", stocks)
        out = tmp_path / "baked"

        assert main(["bake", "--all", "--size", "2", "--out", str(out)]) == 2

        captured = capsys.readouterr()
        assert len(captured.err.splitlines()) == 1
        assert captured.err.startswith(f"error: profile {invalid}: id must be")
        manifests = {path.parent.name for path in out.glob("*/stock.json")}
        assert manifests == {"argent-neutral", "synthetic-v0"}

    def test_bake_reports_working_directory_output_cleanly(self, tmp_path, capsys, monkeypatch):
        monkeypatch.chdir(tmp_path)

        assert main(["bake", "--synthetic", "--size", "5", "--out", "."]) == 2

        captured = capsys.readouterr()
        assert captured.out == ""
        assert captured.err == (
            f"error: refusing to rebake {tmp_path.resolve()}: it is the current working directory or contains it\n"
        )
        assert not list(tmp_path.iterdir())

    def test_bake_synthetic(self, tmp_path, capsys):
        assert main(["bake", "--synthetic", "--size", "9", "--out", str(tmp_path / "s")]) == 0
        out = capsys.readouterr().out
        assert "wrote" in out and 'status is "synthetic"' in out and "per unit dye" in out
        assert (tmp_path / "s" / "stock.json").exists() and (tmp_path / "s" / "print.lut3d").exists()

    def test_bake_from_a_profile_file(self, tmp_path, capsys):
        profile_path = tmp_path / "p.json"
        profile_path.write_text(json.dumps(synthetic.profile_dict()))
        assert main(["bake", "--profile", str(profile_path), "--size", "9", "--out", str(tmp_path / "s")]) == 0

    def test_bake_a_datasheet_stock(self, tmp_path, capsys):
        assert main(["bake", "--profile", str(STOCKS / "portra400.json"), "--size", "9", "--out", str(tmp_path / "s")]) == 0
        out = capsys.readouterr().out
        assert "density range 2.5" in out and 'status is "datasheet"' in out
        manifest = json.loads((tmp_path / "s" / "stock.json").read_text())
        assert manifest["id"] == "kodak-portra-400" and manifest["bake"]["paper"] == "kodak-endura-premier"

    def test_bake_all_writes_one_folder_per_stock(self, tmp_path, capsys):
        assert main(["bake", "--all", "--size", "5", "--out", str(tmp_path / "all")]) == 0
        folders = sorted(p.name for p in (tmp_path / "all").iterdir())
        assert folders == ["argent-neutral", "cinestill-800t", "fujifilm-c200", "fujifilm-pro-400h", "fujifilm-superia-400",
                           "kodak-colorplus-200", "kodak-ektar-100", "kodak-gold-200", "kodak-portra-160",
                           "kodak-portra-160-natural", "kodak-portra-400", "kodak-portra-800", "kodak-ultramax-400",
                           "kodak-vision3-500t", "kodak-vision3-500t-cinema"]
        for folder in folders:
            assert sorted(p.name for p in (tmp_path / "all" / folder).iterdir()) == [
                "negative.cube", "negative.lut3d", "print.cube", "print.lut3d", "stock.json"]
        colorplus = json.loads((tmp_path / "all" / "kodak-colorplus-200" / "stock.json").read_text())
        assert colorplus["status"] == "approximation" and colorplus["bake"]["iso5800Speed"] is None
        tungsten = tmp_path / "all" / "kodak-vision3-500t"
        cinema = tmp_path / "all" / "kodak-vision3-500t-cinema"
        original = json.loads((tungsten / "stock.json").read_text())
        variant = json.loads((cinema / "stock.json").read_text())
        assert original["bake"]["paper"] == "kodak-endura-premier"
        assert "labAimDensity" not in original["bake"] and "modelledPrint" not in original
        assert variant["bake"]["paper"] == "kodak-vision-2383"
        assert variant["bake"]["labAimDensity"] == {"statusA": [1.09, 1.06, 1.03]}
        assert variant["modelledPrint"] == "Kodak VISION Color Print Film 2383"
        for shared in ("modelledFilm", "boxSpeed", "densityRange", "negative", "grain", "halation"):
            assert variant[shared] == original[shared]
        assert (cinema / "negative.lut3d").read_bytes() == (tungsten / "negative.lut3d").read_bytes()
        assert (cinema / "print.lut3d").read_bytes() != (tungsten / "print.lut3d").read_bytes()

    def test_select_one_print_variant(self, tmp_path, capsys):
        args = ["bake", "--profile", str(STOCKS / "vision3500t.json"), "--size", "5", "--out", str(tmp_path / "selected")]
        assert main(args + ["--print-variant", "not-a-variant"]) == 2
        assert "no print variant" in capsys.readouterr().err
        assert not (tmp_path / "selected").exists()
        assert main(args + ["--print-variant", "kodak-vision3-500t-cinema"]) == 0
        manifest = json.loads((tmp_path / "selected" / "stock.json").read_text())
        assert manifest["id"] == "kodak-vision3-500t-cinema"

    @pytest.mark.parametrize("name,status,speed", [
        ("vision3500t", "datasheet", 500), ("cinestill800t", "approximation", 800),
    ])
    def test_tungsten_manifest_keeps_the_stock_halation_and_published_shoulder(self, tmp_path, stocks, endura,
                                                                               name, status, speed):
        profile = stocks[name]
        bake_stock(profile, endura, tmp_path / "stock", size=5)
        manifest = json.loads((tmp_path / "stock" / "stock.json").read_text())
        assert manifest["status"] == status and manifest["boxSpeed"] == speed
        assert manifest["halation"] == profile.halation
        assert manifest["negative"]["logEncoding"]["stopsAboveMidGray"] == 8
        assert manifest["bake"]["highlightShoulder"] == {"source": "published"}
        assert manifest["bake"]["captureIlluminantKelvin"] == 3200
        assert manifest["bake"]["iso5800Speed"] is None

    def test_a_placeholder_profile_is_refused_not_baked(self, tmp_path, capsys):
        data = synthetic.profile_dict()
        data["status"] = "placeholder"
        path = tmp_path / "p.json"
        path.write_text(json.dumps(data))
        assert main(["bake", "--profile", str(path), "--out", str(tmp_path / "s")]) == 2
        assert "placeholder" in capsys.readouterr().err
        assert not (tmp_path / "s").exists()

    def test_an_unknown_paper_is_a_clean_error(self, tmp_path, capsys):
        data = synthetic.profile_dict()
        data["paper"] = "shared-print-model-v1"
        path = tmp_path / "p.json"
        path.write_text(json.dumps(data))
        assert main(["bake", "--profile", str(path), "--size", "9", "--out", str(tmp_path / "s")]) == 2
        assert "no print paper named" in capsys.readouterr().err

    def test_size_is_validated(self, tmp_path):
        with pytest.raises(SystemExit):
            main(["bake", "--synthetic", "--size", "1", "--out", str(tmp_path / "s")])

    def test_check_prints_the_gates(self, capsys):
        assert main(["check", "--profile", str(STOCKS / "portra400.json")]) == 0
        out = capsys.readouterr().out
        for name in ("gray card", "ISO 5800 speed", "unmixing", "cross-talk", "inversion", "density range"):
            assert f"pass  {name}" in out
        assert "all negative gates pass" in out and "-1.5417" in out
        assert "kodak-portra-400 (Portra 400, after Kodak Portra 400, status datasheet" in out
        # The print's tone is reported after the gates, never as one.
        assert "print tone (docs/research/film-sim/print.md" in out and "US5300381 FIG. 2" in out and "US7372597" in out
        assert "print stage acceptance checks" in out
        assert out.index("all negative gates pass") < out.index("print tone")

    def test_check_labels_print_failures_as_advisory(self, capsys):
        assert main(["check", "--profile", str(STOCKS / "ektar100.json")]) == 0
        out = capsys.readouterr().out
        assert "all negative gates pass" in out
        assert "print stage acceptance checks (advisory; do not affect exit status)" in out
        assert "FAIL  neutral axis:" in out

    def test_check_fails_when_a_gate_fails(self, tmp_path, capsys):
        data = json.loads((STOCKS / "portra400.json").read_text())
        data["grayCard"]["redDensity"] = [1.20, 1.30]  # a window the curve cannot reach at mid-gray
        path = tmp_path / "p.json"
        path.write_text(json.dumps(data))
        assert main(["check", "--profile", str(path)]) == 1
        out = capsys.readouterr().out
        assert "FAIL  gray card" in out and "1 negative gate(s) fail" in out

    def test_bake_refuses_a_profile_that_fails_a_gate(self, tmp_path, capsys):
        data = json.loads((STOCKS / "portra400.json").read_text())
        data["grayCard"]["redDensity"] = [1.20, 1.30]
        path = tmp_path / "p.json"
        path.write_text(json.dumps(data))
        assert main(["bake", "--profile", str(path), "--size", "5", "--out", str(tmp_path / "s")]) == 2
        err = capsys.readouterr().err
        assert "gate gray card fails" in err and "not baked" in err
        assert not (tmp_path / "s").exists()
