#!/usr/bin/env python3
# Argent spike, decoder-costs. Measurement prototype, not shipped code.
#
# extract_cfa.py writes the visible Bayer mosaic of an ARW and the metadata a demosaic
# needs, so the Metal harness can start where the in-house tile decoder would hand over:
# a uint16 mosaic in memory. It uses rawpy (LibRaw) only as the unpacker; the mosaic is
# bit-exact with the tile decoder's output on lossless L (lossless-decode/README.md).
#
#   ../../.venv/bin/python extract_cfa.py ../../samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW out/L
#
# writes out/L.cfa (little-endian uint16, row-major, width x height) and out/L.json.

import json
import sys
from pathlib import Path

import numpy as np
import rawpy


def main(arw: str, out: str) -> None:
    out_path = Path(out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with rawpy.imread(arw) as raw:
        mosaic = np.ascontiguousarray(raw.raw_image_visible, dtype="<u2")
        sizes = raw.sizes
        # raw_pattern indexes color_desc (b"RGBG"): 0 R, 1 G, 2 B, 3 the second G.
        pattern = [[{0: 0, 1: 1, 2: 2, 3: 1}[int(v)] for v in row] for row in raw.raw_pattern]
        meta = {
            "file": Path(arw).name,
            "width": int(mosaic.shape[1]),
            "height": int(mosaic.shape[0]),
            "pattern": pattern,
            "black": [int(v) for v in raw.black_level_per_channel],
            "white": int(raw.white_level),
            "camMul": [float(v) for v in raw.camera_whitebalance],
            "xyzToCamera": [[float(v) for v in row] for row in raw.rgb_xyz_matrix[:3]],
            "crop": [int(sizes.crop_left_margin), int(sizes.crop_top_margin), int(sizes.crop_width), int(sizes.crop_height)],
        }
    mosaic.tofile(str(out_path) + ".cfa")
    Path(str(out_path) + ".json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"wrote {out_path}.cfa ({meta['width']}x{meta['height']}) and {out_path}.json")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
