import struct

import numpy as np
import pytest

from argent_bake.cube import grid, read_binary, read_cube, write_binary, write_cube


def test_grid_runs_red_fastest():
    rows = list(grid(2, lambda r, g, b: (r, g, b)))
    assert rows == [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1)]


def test_round_trip(tmp_path):
    path = tmp_path / "lut.cube"
    write_cube(str(path), 3, "round trip", grid(3, lambda r, g, b: (r, g * 0.5, b * 0.25)))
    size, rows = read_cube(str(path))
    assert size == 3 and len(rows) == 27
    assert rows[1] == pytest.approx((0.5, 0.0, 0.0))
    assert rows[3] == pytest.approx((0.0, 0.25, 0.0))
    assert rows[9] == pytest.approx((0.0, 0.0, 0.125))  # blue is 0.5 on the middle plane, scaled by 0.25
    assert path.read_text().splitlines()[:2] == ['TITLE "round trip"', "LUT_3D_SIZE 3"]


def test_reader_rejects_a_short_file(tmp_path):
    path = tmp_path / "short.cube"
    path.write_text("LUT_3D_SIZE 2\n0 0 0\n")
    with pytest.raises(ValueError, match="entries"):
        read_cube(str(path))


def test_binary_round_trip_and_layout(tmp_path):
    path = tmp_path / "lut.lut3d"
    write_binary(str(path), 3, grid(3, lambda r, g, b: (r, g * 0.5, b * 0.25)))
    data = path.read_bytes()
    assert data[:8] == b"ARGLUT3D"
    assert struct.unpack("<II", data[8:16]) == (1, 3)
    assert len(data) == 16 + 4 * 3 * 27
    # Node ((b * size) + g) * size + r, three little-endian float32 values: node 2 is red 1.0.
    assert struct.unpack("<3f", data[16 + 24:16 + 36]) == (1.0, 0.0, 0.0)
    assert struct.unpack("<3f", data[16 + 9 * 12:16 + 10 * 12]) == pytest.approx((0.0, 0.0, 0.125))
    size, rows = read_binary(str(path))
    assert size == 3 and len(rows) == 27
    assert rows[1] == pytest.approx((0.5, 0.0, 0.0))
    assert rows[3] == pytest.approx((0.0, 0.25, 0.0))


def test_binary_and_cube_agree(tmp_path):
    rows = list(grid(4, lambda r, g, b: (r ** 2, g * 0.3, 1 - b)))
    write_cube(str(tmp_path / "a.cube"), 4, "a", rows)
    write_binary(str(tmp_path / "a.lut3d"), 4, rows)
    _, from_cube = read_cube(str(tmp_path / "a.cube"))
    _, from_binary = read_binary(str(tmp_path / "a.lut3d"))
    for a, b in zip(from_cube, from_binary):
        assert a == pytest.approx(b, abs=1e-6)


@pytest.mark.parametrize("dtype", [np.float32, ">f8"])
def test_array_writers_match_iterable_writers(tmp_path, dtype):
    size = 11  # Covers a full text chunk and a partial chunk.
    rows = np.asfortranarray(list(grid(size, lambda r, g, b: (r / 3, g / 7, b / 11 - 0.5))), dtype=dtype)
    for name, values in (("array", rows), ("iterable", rows.tolist())):
        write_cube(str(tmp_path / f"{name}.cube"), size, "matching rows", values)
        write_binary(str(tmp_path / f"{name}.lut3d"), size, values)

    for extension in ("cube", "lut3d"):
        assert (tmp_path / f"array.{extension}").read_bytes() == (tmp_path / f"iterable.{extension}").read_bytes()


def test_cube_writer_rejects_arrays_without_rgb_rows(tmp_path):
    with pytest.raises(ValueError, match="RGB rows"):
        write_cube(str(tmp_path / "x.cube"), 2, "bad rows", np.zeros((8, 2)))


@pytest.mark.parametrize("corrupt, message", [
    (lambda d: b"NOTALUT3D" + d[9:], "not an ARGLUT3D"),
    (lambda d: d[:8] + struct.pack("<II", 2, 3) + d[16:], "version 2"),
    (lambda d: d[:-4], "bytes"),
    (lambda d: d[:8] + struct.pack("<II", 1, 1) + d[16:], "size 1"),
])
def test_binary_reader_rejects_bad_files(tmp_path, corrupt, message):
    path = tmp_path / "lut.lut3d"
    write_binary(str(path), 3, grid(3, lambda r, g, b: (r, g, b)))
    path.write_bytes(corrupt(path.read_bytes()))
    with pytest.raises(ValueError, match=message):
        read_binary(str(path))


def test_binary_writer_checks_the_row_count_and_size(tmp_path):
    with pytest.raises(ValueError, match="rows"):
        write_binary(str(tmp_path / "x.lut3d"), 3, [(0.0, 0.0, 0.0)])
    with pytest.raises(ValueError, match="rows"):
        write_binary(str(tmp_path / "x.lut3d"), 2, np.zeros((12, 2)))
    with pytest.raises(ValueError, match="size"):
        write_binary(str(tmp_path / "x.lut3d"), 1, [(0.0, 0.0, 0.0)])
