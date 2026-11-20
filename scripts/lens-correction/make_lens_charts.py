"""Write four 7008 x 4672 LinearRaw DNGs and their measurement layouts.

python -I make_lens_charts.py OUT --lens-model 'TAMRON 28-75mm F2.8' \
    --focal-length 75 --f-number 2.8 --lens-spec 28 75 2.8 2.8
Levels and chroma are scene-linear RGB, white = 1. Fringe chroma is the
RGB offset from neutral. Hue is measured about the (1,1,1) neutral axis:
0 degrees projects toward (1,-2,1), 90 toward (1,0,-1). The original
purple (+c,-c,+c) and green (-c,+c,-c) are at 0 and 180 degrees.
"""
import argparse
import json
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lightroom-probe"))
import make_charts  # noqa: E402

WIDTH, HEIGHT = 7008, 4672


def lens_metadata(path, lens, focal, fnumber, specification):
    """Append EXIF and a new root IFD to the shared writer's DNG; keep its pixels.

    TIFF offsets stay absolute. The old IFD's entries, including strip offsets
    and the embedded linear camera matrix, remain valid in the new root.
    """
    def append_ifd(file, entries):
        entries = sorted(entries)
        start = file.tell()
        extra, rows = bytearray(), []
        data_start = start + 6 + 12 * len(entries)
        for tag, kind, count, value in entries:
            if len(value) > 4:
                if len(extra) % 2:
                    extra += b"\0"
                packed = struct.pack("<I", data_start + len(extra))
                extra += value
            else:
                packed = value.ljust(4, b"\0")
            rows.append(struct.pack("<HHI", tag, kind, count) + packed)
        file.write(struct.pack("<H", len(rows)) + b"".join(rows) + b"\0" * 4 + extra)
        if file.tell() % 2:
            file.write(b"\0")
        return start

    with Path(path).open("r+b") as file:
        file.seek(4)
        file.seek(struct.unpack("<I", file.read(4))[0])
        count = struct.unpack("<H", file.read(2))[0]
        root = [struct.unpack("<HHI4s", file.read(12)) for _ in range(count)]
        file.seek(0, 2)
        exif = append_ifd(file, [make_charts.rational(33437, fnumber),
                                make_charts.rational(37386, focal),
                                make_charts.rational(42034, *specification),
                                make_charts.ascii_(42036, lens)])
        replace = [make_charts.ascii_(271, "SONY"), make_charts.ascii_(272, "ILCE-7M4"),
                   make_charts.ascii_(50708, "Sony ILCE-7M4"),
                   make_charts.rational(50736, *specification), make_charts.long_(34665, exif)]
        tags = {entry[0] for entry in replace}
        # Existing four-byte fields are already inline values or absolute offsets.
        offset = append_ifd(file, [entry for entry in root if entry[0] not in tags] + replace)
        file.seek(4)
        file.write(struct.pack("<I", offset))


def fringe_layout(width, height, fringe_width, chroma, dense=False, hue_step=10):
    """Hue = degrees(atan2((R-B)/sqrt(2), (R-2G+B)/sqrt(6))) modulo 360."""
    regions, bars = [], []
    stimuli = [(hue, fringe_width) for hue in range(0, 360, hue_step)]
    stimuli += [(hue, size) for hue in (0, 180) for size in (2, 6, 12) if size != fringe_width]
    if dense:
        stimuli += [(hue, 6) for start in (276, 56, 164, 206) for hue in range(start, start + 25, 2)
                    if (hue, 6) not in stimuli]
    row_count = (len(stimuli) + 5) // 6
    for index, (hue, size) in enumerate(stimuli):
        col, row = index % 6, index // 6
        left, right = round(width * col / 6), round(width * (col + 1) / 6)
        top, bottom = round(height * row / row_count), round(height * (row + 1) / row_count)
        cell_width, cell_height = right - left, bottom - top
        x, half = (left + right) // 2, round(cell_width * 0.1)
        y0, y1 = top + round(cell_height * 0.12), top + round(cell_height * 0.62)
        if x - half - 4 * size <= left or x + half + 4 * size >= right or y1 <= y0:
            raise ValueError("fringe chart cells are too small for the requested fringe widths")
        bars.append([x - half, y0, x + half, y1])
        # The projected offset has constant radius in the neutral-orthogonal
        # plane. Its neutral component preserves the original two RGB offsets.
        if hue in (0, 180):
            offset = chroma * np.array([1, -1, 1]) * (1 if hue == 0 else -1)
        else:
            theta = np.deg2rad(hue)
            offset = chroma * (np.cos(theta) * np.array([1, -1, 1]) +
                               np.sin(theta) * np.sqrt(4 / 3) * np.array([1, 0, -1]))
        if np.any(0.65 + offset > 1) or np.any(0.4 + offset < 0):
            raise ValueError("fringe hue wheel exceeds linear RGB range; reduce --chroma")
        metadata = {"colour": {0: "purple", 180: "green"}.get(hue, f"hue-{hue:03}"),
                    "hue_degrees": hue, "rgb_offset": offset.tolist(), "fringe_width_px": size}
        # Both edges have fringe on the bright side and a neutral reference
        # beyond it. The matching solid patch below the bar must survive.
        for edge, side in ((x - half, -1), (x + half, 1)):
            a, b = sorted((edge, edge + side * size))
            r0, r1 = sorted((edge + side * size * 3, edge + side * size * 4))
            regions.append(metadata | {"kind": "fringe", "box": [a, y0, b, y1],
                                       "reference": [r0, y0, r1, y1]})
        regions.append(metadata | {"kind": "protected",
                                   "box": [left + round(cell_width * 0.25), top + round(cell_height * 0.76),
                                           left + round(cell_width * 0.75), top + round(cell_height * 0.94)]})
    return {"width": width, "height": height, "fringe_width_px": fringe_width,
            "fringe_widths_px": sorted({size for _, size in stimuli}), "chroma_offset": chroma,
            "hue_plane": {"neutral_axis": [1, 1, 1], "zero_degrees": [1, -2, 1],
                          "positive_90_degrees": [1, 0, -1]},
            "bars": bars, "regions": regions}


def fringe(width=WIDTH, height=HEIGHT, fringe_width=6, chroma=0.12, dense=False, hue_step=10):
    layout = fringe_layout(width, height, fringe_width, chroma, dense, hue_step)
    image = np.full((height, width, 3), 0.65, dtype=np.float32)
    for x0, y0, x1, y1 in layout["bars"]:
        image[y0:y1, x0:x1] = 0.06
    for region in layout["regions"]:
        x0, y0, x1, y1 = region["box"]
        level = 0.65 if region["kind"] == "fringe" else 0.4
        image[y0:y1, x0:x1] = level + np.array(region["rgb_offset"])
    return image, layout


def blurred_edges():
    """Infinite Gaussian steps, sampled at pixel centres in linear sRGB.

    The analysis rectangle is 600 px along the edge and 400 px across it,
    safely inside each larger rendered box, including the two slanted edges.
    """
    from scipy.special import ndtr

    neutral, sky = [0.9] * 3, [0.35, 0.55, 0.9]
    dark, foliage, brown = [0.02] * 3, [0.02, 0.035, 0.012], [0.04, 0.025, 0.015]
    specs = [("neutral", dark, neutral, [3, 1, 3], 0, None),
             ("sky", dark, sky, [3, 1, 3], 0, None),
             ("foliage", foliage, neutral, [3, 1, 3], 0, None),
             ("brown", brown, neutral, [3, 1, 3], 0, None),
             ("brown-sky", brown, sky, [3, 1, 3], 0, None),
             ("wide", dark, neutral, [6, 2, 6], 0, None),
             ("narrow", dark, neutral, [1.5, 0.5, 1.5], 0, None),
             ("slant-22p5", dark, neutral, [3, 1, 3], 22.5, None),
             ("slant-45", dark, neutral, [3, 1, 3], 45, None),
             ("line-4", dark, neutral, [3, 1, 3], 0, 4),
             ("line-12", dark, neutral, [3, 1, 3], 0, 12),
             ("swapped", dark, neutral, [1, 3, 1], 0, None)]
    image = np.full((HEIGHT, WIDTH, 3), 0.18, np.float32)
    stimuli = []
    for i, (name, lo, hi, sigmas, angle, line_width) in enumerate(specs):
        cx, cy = (i % 4 + 0.5) * WIDTH / 4, (i // 4 + 0.5) * HEIGHT / 3
        box = [round(cx - 700), round(cy - 650), round(cx + 700), round(cy + 650)]
        x0, y0, x1, y1 = box
        yy, xx = np.mgrid[y0:y1, x0:x1]
        theta = np.deg2rad(angle)
        d = (xx + 0.5 - cx) * np.cos(theta) - (yy + 0.5 - cy) * np.sin(theta)
        for channel, sigma in enumerate(sigmas):
            blend = (ndtr(d / sigma) if line_width is None else
                     1 - (ndtr((d + line_width / 2) / sigma) - ndtr((d - line_width / 2) / sigma)))
            image[y0:y1, x0:x1, channel] = lo[channel] + (hi[channel] - lo[channel]) * blend
        stimuli.append(dict(name=name, box=box, center=[cx, cy], angle_from_vertical=angle,
                            dark_rgb=lo, bright_rgb=hi, sigma_rgb_px=sigmas, line_width_px=line_width,
                            sides=("negative normal dark; positive normal bright" if line_width is None else
                                   "dark inside line; bright on both sides"),
                            analysis_normal_px=[-200, 200], analysis_tangent_px=[-300, 300]))
    return image, dict(width=WIDTH, height=HEIGHT, encoding="linear sRGB", stimuli=stimuli)


def chart(name, level, fringe_width, chroma):
    layout = {"width": WIDTH, "height": HEIGHT}
    if name == "fringe":
        return fringe(fringe_width=fringe_width, chroma=chroma)
    image = np.full((HEIGHT, WIDTH, 3), level if name == "flat" else 0.18, dtype=np.float32)
    if name == "grid":
        spacing, radius = 96, 6
        yy, xx = np.mgrid[-radius:radius + 1, -radius:radius + 1]
        disk = xx * xx + yy * yy <= radius * radius
        for y in range(spacing // 2, HEIGHT - radius, spacing):
            for x in range(spacing // 2, WIDTH - radius, spacing):
                image[y - radius:y + radius + 1, x - radius:x + radius + 1][disk] = 0.015
        layout.update(spacing_px=spacing, dot_radius_px=radius, background=0.18, dots=0.015)
    elif name == "edges":
        edges = []
        size = 192
        yy, xx = np.mgrid[:size, :size] - (size - 1) / 2
        for radius in (0, 0.2, 0.4, 0.6, 0.8):
            for angle in ((0,) if radius == 0 else range(0, 360, 45)):
                theta = np.deg2rad(angle)
                x, y = round(WIDTH / 2 + radius * WIDTH / 2 * np.cos(theta)), round(HEIGHT / 2 + radius * HEIGHT / 2 * np.sin(theta))
                slant = theta + np.deg2rad(7)
                edge = np.clip((xx * np.cos(slant) + yy * np.sin(slant)) + 0.5, 0, 1)
                image[y - size // 2:y + size // 2, x - size // 2:x + size // 2] = (0.04 + 0.5 * edge)[..., None]
                edges.append({"center": [x, y], "normal_degrees": angle + 7, "size": size})
        layout["edges"] = edges
    else:
        layout["level"] = level
    return image, layout


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("out", type=Path)
    parser.add_argument("--neutral-round", action="store_true",
                        help="write only the 5-degree neutral fringe wheel and the twelve blurred-edge stimuli")
    parser.add_argument("--neutral-fringe", action="store_true",
                        help="write only fringe-neutral, with dense boundary hues and the embedded matrix, no camera/lens tags")
    parser.add_argument("--lens-model")
    parser.add_argument("--focal-length", type=float)
    parser.add_argument("--f-number", type=float)
    parser.add_argument("--lens-spec", type=float, nargs=4, metavar=("MIN_MM", "MAX_MM", "MIN_F", "MAX_F"))
    parser.add_argument("--level", type=float, default=0.18, help="flat field's linear level, 0 < level < 1")
    parser.add_argument("--fringe-width", type=int, default=6)
    parser.add_argument("--chroma", type=float, default=0.12)
    args = parser.parse_args()
    if not 0 < args.level < 1 or not 0 < args.chroma < 0.35 or not 1 <= args.fringe_width <= 64:
        parser.error("require 0 < level < 1, 0 < chroma < 0.35 and 1 <= fringe-width <= 64")
    if args.neutral_round:
        args.out.mkdir(parents=True, exist_ok=True)
        for name, (image, layout) in (("fringe-wheel", fringe(hue_step=5)), ("fringe-edges", blurred_edges())):
            path = args.out / f"{name}.dng"
            make_charts.write_dng(path, np.round(image * 65535).astype("<u2"))
            (args.out / f"{name}-layout.json").write_text(json.dumps(layout, indent=2) + "\n")
            print(path)
        return
    if args.neutral_fringe:
        args.out.mkdir(parents=True, exist_ok=True)
        image, layout = fringe(fringe_width=args.fringe_width, chroma=args.chroma, dense=True)
        path = args.out / "fringe-neutral.dng"
        make_charts.write_dng(path, np.round(image * 65535).astype("<u2"))
        (args.out / "fringe-neutral-layout.json").write_text(json.dumps(layout, indent=2) + "\n")
        print(path)
        return
    if any(v is None for v in (args.lens_model, args.focal_length, args.f_number, args.lens_spec)):
        parser.error("camera-tagged charts require all four lens metadata options")
    if not all(np.isfinite(v) and 0 < v < 10000 for v in [args.focal_length, args.f_number, *args.lens_spec]):
        parser.error("lens metadata must contain finite positive values below 10000")
    args.out.mkdir(parents=True, exist_ok=True)
    metadata = {"make": "SONY", "model": "ILCE-7M4", "lens_model": args.lens_model,
                "focal_length": args.focal_length, "f_number": args.f_number, "lens_spec": args.lens_spec}
    for name in ("grid", "edges", "flat", "fringe"):
        image, layout = chart(name, args.level, args.fringe_width, args.chroma)
        path = args.out / f"{name}.dng"
        make_charts.write_dng(path, np.round(image * 65535).astype("<u2"))
        lens_metadata(path, args.lens_model, args.focal_length, args.f_number, args.lens_spec)
        (args.out / f"{name}-layout.json").write_text(json.dumps(layout | metadata, indent=2) + "\n")
        print(path)


if __name__ == "__main__":
    main()
