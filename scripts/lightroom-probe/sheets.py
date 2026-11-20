"""Comparison sheets of the probe raw: two Argent scorecards' renders and Lightroom's, side by side
(docs/research/lightroom-sliders.md).

For each control at its extremes (Exposure at -2 and +2 EV), one sheet whose rows are the base,
the negative extreme and the positive extreme and whose columns are the first label's render, the
second's and Lightroom's, all at the scorecard's 1752 pixels, sRGB. With --crops, each named
region of each render at the scorecard's own pixels, columns as the sheets', one file per region.
With --full, the same rows and columns for each of FULL_REGIONS at the raw's own 7008 pixels, 1:1:
the spike renders the probe raw whole with each label's compiler (--before-version,
--after-version), and the renders are deleted once cropped.

    python -I scripts/lightroom-probe/sheets.py BEFORE AFTER [--stock ID] [--out DIR] [--crops]
        [--full --before-version V --after-version V [--controls C,...]]

BEFORE and AFTER are score.py labels (folders under DATA/score). Writes DATA/score/AFTER/sheets/
unless --out says otherwise.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe  # noqa: E402

# Linear ProPhoto RGB (D50) to linear sRGB (D65), through XYZ and Bradford adaptation.
PROPHOTO_TO_XYZ = np.array([[0.7976749, 0.1351917, 0.0313534],
                            [0.2880402, 0.7118741, 0.0000857],
                            [0.0000000, 0.0000000, 0.8252100]])
BRADFORD_D50_TO_D65 = np.array([[0.9555766, -0.0230393, 0.0631636],
                                [-0.0282895, 1.0099416, 0.0210077],
                                [0.0122982, -0.0204830, 1.3299098]])
XYZ_TO_SRGB = np.array([[3.2404542, -1.5371385, -0.4985314],
                        [-0.9692660, 1.8760108, 0.0415560],
                        [0.0556434, -0.2040259, 1.0572252]])
PROPHOTO_TO_SRGB = XYZ_TO_SRGB @ BRADFORD_D50_TO_D65 @ PROPHOTO_TO_XYZ
EXTREMES = {"exposure": (-2.0, 2.0)} | {c: (-100, 100) for c in probe.CONTROLS}
# Regions of the probe raw at the scorecard's 1752 x 1168, (left, top, right, bottom): the edges
# where a local control's halo would show (leaves against the sky, the walls against the gate and
# the foliage), the dark gate whose noise Shadows and Blacks lift, and the white wall.
REGIONS = {
    "sky-left": (0, 0, 440, 300),
    "sky-right": (1312, 100, 1752, 400),
    "wall-gate": (400, 760, 840, 1060),
    "white-wall": (1240, 820, 1680, 1120),
    "gate-dark": (620, 868, 1060, 1168),
}

# Regions at the raw's own 7008 x 4672, 600 x 400 each: leaves against the white building behind
# them, the white wall under the dark foliage and its tiles, the sign's pole against the wall, the
# beige wall's bricks against the dark gate, and the gate's shadows.
FULL_REGIONS = {
    "leaves-building": (160, 240, 760, 640),
    "wall-foliage": (5760, 3320, 6360, 3720),
    "pole-wall": (6240, 3600, 6840, 4000),
    "wall-gate": (2160, 3520, 2760, 3920),
    "gate-dark": (2800, 4000, 3400, 4400),
}


def encode(linear):
    """sRGB-encoded 8-bit RGB of linear sRGB."""
    v = np.clip(linear, 0, 1)
    v = np.where(v <= 0.0031308, 12.92 * v, 1.055 * np.power(v, 1 / 2.4) - 0.055)
    return (v * 255 + 0.5).astype(np.uint8)


def lightroom_image(path, size):
    """A Lightroom export as 8-bit sRGB, area-averaged in linear light to `size` (width, height)."""
    img, icc = probe.read_tiff(path)
    linear = np.power(img, probe.icc_gamma(icc)) @ PROPHOTO_TO_SRGB.T
    k = img.shape[1] // size[0]
    h, w = size[1] * k, size[0] * k
    linear = linear[:h, :w].reshape(size[1], k, size[0], k, 3).mean(axis=(1, 3))
    return Image.fromarray(encode(linear))


def argent_image(path, box=None):
    img, _ = probe.read_tiff(path)
    if box:
        img = img[box[1]:box[3], box[0]:box[2]]
    return Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8))


def lightroom_crop(path, box):
    """A region of a Lightroom export at its own pixels, as 8-bit sRGB."""
    img, icc = probe.read_tiff(path)
    linear = np.power(img[box[1]:box[3], box[0]:box[2]], probe.icc_gamma(icc)) @ PROPHOTO_TO_SRGB.T
    return Image.fromarray(encode(linear))


def full_sheets(args, scene, out):
    """Each FULL_REGIONS crop of each control's extremes, Argent's two compilers rendered whole."""
    raw = probe.DATA / "raw" / "raw_00_base.ARW"
    stock = probe.ROOT / "build" / "stocks" / args.stock
    work = probe.DATA / "score" / args.after / "full"
    flag = {"exposure": "--exposure-ev"} | {c: f"--{c}" for c in probe.CONTROLS}
    controls = args.controls.split(",") if args.controls else list(EXTREMES)

    def crops(control, value):
        """The regions of the two compilers' renders and Lightroom's, by region."""
        cells = {region: [] for region in FULL_REGIONS}
        for version in (args.before_version, args.after_version):
            folder = work / version
            extra = [] if control is None else [flag[control], value]
            probe.spike(raw, folder, stock, "--auto", "--tiff", "--no-lens", "--manual-version", version, *extra)
            path = folder / (raw.stem + ".tif")
            for region, box in FULL_REGIONS.items():
                cells[region].append(argent_image(path, box))
            path.unlink()
        for region, box in FULL_REGIONS.items():
            cells[region].append(lightroom_crop(scene(control, value), box))
        return cells

    base = crops(None, 0)
    for control in controls:
        rows = {region: [base[region]] for region in FULL_REGIONS}
        titles = [[f"{args.before} base", f"{args.after} base", "Lightroom base"]]
        for value in EXTREMES[control]:
            name = probe.variant_name(control, value)
            for region, cells in crops(control, value).items():
                rows[region].append(cells)
            titles.append([f"{args.before} {name}", f"{args.after} {name}", f"Lightroom {name}"])
        for region in FULL_REGIONS:
            grid(rows[region], titles, 1).save(out / f"{args.stock}-full-{control}-{region}.png")
        print(f"wrote full {control}", flush=True)


def renders(before, after, stock, scene, control, value):
    """The three renders of a control at a value (control None: the base)."""
    name = "base" if control is None else probe.variant_name(control, value)
    cells = [argent_image(probe.DATA / "score" / label / stock / name / "raw_00_base.tif") for label in (before, after)]
    cells.append(lightroom_image(scene(control, value), cells[0].size))
    return cells


def label(image, text):
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, 8 + 7 * len(text), 16), fill=(0, 0, 0))
    draw.text((4, 2), text, fill=(255, 255, 255))
    return image


def grid(rows, titles, scale):
    w, h = rows[0][0].size
    cw, ch = int(w * scale), int(h * scale)
    sheet = Image.new("RGB", (3 * cw + 8, len(rows) * ch + 4 * (len(rows) - 1)), (40, 40, 40))
    for r, (cells, title) in enumerate(zip(rows, titles)):
        for c, cell in enumerate(cells):
            sheet.paste(label(cell.resize((cw, ch), Image.LANCZOS) if scale != 1 else cell.copy(), title[c]),
                        (c * (cw + 4), r * (ch + 4)))
    return sheet


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--stock", default="kodak-portra-400")
    parser.add_argument("--exports", default=probe.DATA / "exports")
    parser.add_argument("--out")
    parser.add_argument("--crops", action="store_true", help="also each region at the scorecard's own pixels")
    parser.add_argument("--full", action="store_true", help="crops at the raw's own pixels, rendered whole")
    parser.add_argument("--before-version", default="2026-10-09-1", help="--full: BEFORE's manual compiler")
    parser.add_argument("--after-version", default="2026-10-29-1", help="--full: AFTER's manual compiler")
    parser.add_argument("--controls", help="--full: the controls, comma-separated (default: all)")
    args = parser.parse_args()
    out = Path(args.out) if args.out else probe.DATA / "score" / args.after / "sheets"
    out.mkdir(parents=True, exist_ok=True)

    exports = Path(args.exports)

    def scene(control, value):
        if control is None:
            return exports / "raw_00_base.tif"
        index = probe.variants().index((control, value))
        return exports / f"raw_{index:02d}_{probe.variant_name(control, value)}.tif"

    if args.full:
        full_sheets(args, scene, out)
        return
    base = renders(args.before, args.after, args.stock, scene, None, 0)
    for control, extremes in EXTREMES.items():
        rows, titles = [base], [[f"{args.before} base", f"{args.after} base", "Lightroom base"]]
        for value in extremes:
            name = probe.variant_name(control, value)
            rows.append(renders(args.before, args.after, args.stock, scene, control, value))
            titles.append([f"{args.before} {name}", f"{args.after} {name}", f"Lightroom {name}"])
        grid(rows, titles, 0.5).save(out / f"{args.stock}-{control}.png")
        if args.crops:
            for region, box in REGIONS.items():
                cropped = [[cell.crop(box) for cell in row] for row in rows]
                grid(cropped, titles, 1).save(out / f"{args.stock}-{control}-{region}.png")
        print(f"wrote {control}", flush=True)


if __name__ == "__main__":
    main()
