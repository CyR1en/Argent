"""The film render's input and output as arrays, through argent-spike's --scene-out, --scene-in and --print-out.

A fit prototypes a stage in Python on the scene the render receives, renders the changed scene through Argent's
real film chain, and compares the print with Lightroom's export in CIE XYZ under D50, the ICC connection space.
Both arrays are (height, width, 3) float32, top row first, in linear Rec. 2020 primaries with a D65 white:

- the scene: scene-linear light as decoded, middle gray 0.18, unclipped, at the decode's size. `--scale` sets that
  size; `--long-edge` resizes only the spike's picture, so the arrays stay at the decode's size.
- the print: display-linear light, 1 the display's white, before the resize, the conversion to sRGB and the encode.

The render holds the scene in half floats, so a scene array is rounded to them on the way in. With `--auto` the aim
is measured on the raw's own decode, whatever scene is rendered; the render's base fields (Auto's tone step,
Highlights and Shadows, halation) are made from the scene it is given.
"""
import struct
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe  # noqa: E402

D65 = (0.3127, 0.3290)
# The ICC connection space's white, which Lightroom's ProPhoto profile states as its own (wtpt).
D50 = np.array([0.9642, 1.0, 0.8249])
REC2020 = [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)]
BRADFORD = np.array([[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]])


def _rgb_to_xyz(primaries, white_xy):
    """Linear RGB with these xy primaries and white to XYZ, the white at Y = 1."""
    P = np.array([[x / y, 1, (1 - x - y) / y] for x, y in primaries]).T
    W = np.array([white_xy[0] / white_xy[1], 1, (1 - white_xy[0] - white_xy[1]) / white_xy[1]])
    return P * np.linalg.solve(P, W)


def _bradford(source, target):
    s, t = BRADFORD @ source, BRADFORD @ target
    return np.linalg.inv(BRADFORD) @ np.diag(t / s) @ BRADFORD


_D65_TO_XYZ = _rgb_to_xyz(REC2020, D65)
REC2020_TO_XYZ_D50 = _bradford(_D65_TO_XYZ @ np.ones(3), D50) @ _D65_TO_XYZ


def scene_of(raw, stock, *flags, binary=None, out=None):
    """The scene argent-spike's film render receives for `raw` with `flags`. In `out`, when given, the spike's
    picture and scene.npy stay; otherwise they go."""
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(out or temporary)
        probe.spike(raw, folder, stock, *flags, "--scene-out", folder / "scene.npy", binary=binary)
        return np.load(folder / "scene.npy")


def print_of(raw, stock, scene, *flags, binary=None, out=None):
    """The print of `scene` rendered in place of `raw`'s decode with `flags`. Give it the flags `scene_of` was given,
    so the decode it replaces has the scene's size; the spike refuses any other. In `out`, when given, the spike's
    picture, scene.npy and print.npy stay."""
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(out or temporary)
        folder.mkdir(parents=True, exist_ok=True)
        np.save(folder / "scene.npy", np.ascontiguousarray(scene, dtype=np.float32))
        probe.spike(raw, folder, stock, *flags, "--scene-in", folder / "scene.npy", "--print-out", folder / "print.npy",
                    binary=binary)
        return np.load(folder / "print.npy")


def print_xyz(print_array):
    """A print array as CIE XYZ under D50 (Bradford from the print's D65 white), white Y = 1: the space
    `lightroom_xyz` reads a ProPhoto export into."""
    return print_array @ REC2020_TO_XYZ_D50.astype(np.float32).T


def lightroom_xyz(path):
    """A Lightroom export read by `probe.read_tiff`, as CIE XYZ under D50, white Y = 1: its profile's pure gamma
    undone and its own colorants (rXYZ, gXYZ, bXYZ) applied, as ICC colour management reads it."""
    image, icc = probe.read_tiff(path)
    gamma = probe.icc_gamma(icc) if icc else None
    if gamma is None:
        raise SystemExit(f"{path}: expected an export with a pure-gamma matrix profile, such as ProPhoto RGB")
    count = struct.unpack(">I", icc[128:132])[0]
    tags = {}
    for i in range(count):
        signature, offset, _ = struct.unpack(">4sII", icc[132 + 12 * i:144 + 12 * i])
        tags[signature] = offset
    columns = [[v / 65536 for v in struct.unpack(">3i", icc[tags[s] + 8:tags[s] + 20])] for s in (b"rXYZ", b"gXYZ", b"bXYZ")]
    return np.power(image, gamma) @ np.array(columns, dtype=np.float32)
