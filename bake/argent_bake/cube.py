"""Write Resolve/Adobe-style .cube files and the binary .lut3d beside them, red fastest,
matching LUT3D.swift.

The binary format, little-endian: 8 ASCII bytes "ARGLUT3D", uint32 version 1, uint32 size
(2 to 128), then size cubed times three float32 values in .cube order (node index
((b * size) + g) * size + r, three floats per node, R G B). No trailer, no padding. The
Swift loader prefers it when the manifest names it, because parsing the text file takes
hundreds of milliseconds.
"""

import struct
import sys
from array import array
from typing import Callable, Iterable, Tuple

import numpy as np

RGB = Tuple[float, float, float]

BINARY_MAGIC = b"ARGLUT3D"
BINARY_VERSION = 1
MIN_SIZE = 2
MAX_SIZE = 128
CUBE_CHUNK_ROWS = 1024


def write_cube(path: str, size: int, title: str, rows: Iterable[RGB] | np.ndarray) -> None:
    row_format = "%.6f %.6f %.6f\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(f'TITLE "{title}"\n')
        f.write(f"LUT_3D_SIZE {size}\n")
        if isinstance(rows, np.ndarray):
            if rows.ndim != 2 or rows.shape[1] != 3:
                raise ValueError(f"expected RGB rows, got array of shape {rows.shape}")
            for start in range(0, len(rows), CUBE_CHUNK_ROWS):
                chunk = rows[start:start + CUBE_CHUNK_ROWS]
                f.write((row_format * len(chunk)) % tuple(chunk.flat))
        else:
            for r, g, b in rows:
                f.write(f"{r:.6f} {g:.6f} {b:.6f}\n")


def grid(size: int, fn: Callable[[float, float, float], RGB]) -> Iterable[RGB]:
    """Evaluate fn over the unit cube in .cube order: red fastest, then green, then blue."""
    d = size - 1
    for b in range(size):
        for g in range(size):
            for r in range(size):
                yield fn(r / d, g / d, b / d)


def read_cube(path: str) -> Tuple[int, list]:
    """Read a .cube written by write_cube. Returns the size and the rows in file order."""
    size = 0
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if not parts or parts[0].startswith("#") or parts[0] in ("TITLE", "DOMAIN_MIN", "DOMAIN_MAX"):
                continue
            if parts[0] == "LUT_3D_SIZE":
                size = int(parts[1])
            else:
                rows.append(tuple(float(v) for v in parts))
    if len(rows) != size ** 3:
        raise ValueError(f"{path} has {len(rows)} entries but LUT_3D_SIZE {size} implies {size ** 3}")
    return size, rows


def write_binary(path: str, size: int, rows: Iterable[RGB] | np.ndarray) -> None:
    """Write the .lut3d file: header, then the rows as little-endian float32 in .cube order."""
    if not MIN_SIZE <= size <= MAX_SIZE:
        raise ValueError(f"binary LUT size must be {MIN_SIZE} to {MAX_SIZE}, not {size}")
    if isinstance(rows, np.ndarray):
        if rows.shape != (size ** 3, 3):
            raise ValueError(f"size {size} needs {size ** 3} RGB rows, got array of shape {rows.shape}")
        values = np.ascontiguousarray(rows, dtype="<f4")
    else:
        values = array("f", (float(v) for row in rows for v in row))
        if len(values) != 3 * size ** 3:
            raise ValueError(f"{len(values) // 3} rows given but size {size} needs {size ** 3}")
        if sys.byteorder != "little":
            values.byteswap()
    with open(path, "wb") as f:
        f.write(BINARY_MAGIC + struct.pack("<II", BINARY_VERSION, size))
        f.write(values)


def read_binary(path: str) -> Tuple[int, list]:
    """Read a .lut3d file. Returns the size and the rows in file order, as float32 values."""
    with open(path, "rb") as f:
        data = f.read()
    header = len(BINARY_MAGIC) + 8
    if len(data) < header or data[:len(BINARY_MAGIC)] != BINARY_MAGIC:
        raise ValueError(f"{path} is not an ARGLUT3D file")
    version, size = struct.unpack("<II", data[len(BINARY_MAGIC):header])
    if version != BINARY_VERSION:
        raise ValueError(f"{path} is binary LUT version {version}; this reader knows version {BINARY_VERSION}")
    if not MIN_SIZE <= size <= MAX_SIZE:
        raise ValueError(f"{path} has size {size}, outside {MIN_SIZE} to {MAX_SIZE}")
    expected = header + 4 * 3 * size ** 3
    if len(data) != expected:
        raise ValueError(f"{path} has {len(data)} bytes but size {size} implies {expected}")
    values = array("f")
    values.frombytes(data[header:])
    if sys.byteorder != "little":
        values.byteswap()
    return size, [tuple(values[i:i + 3]) for i in range(0, len(values), 3)]
