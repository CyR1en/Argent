#!/usr/bin/env python3
"""Compare the grain in finished film scans with the model's, where their light matches.

Each scan is a JPEG of a whole 36 mm frame, given with the stock it was shot on. In its upper
third the flattest 128-pixel tiles are taken as sky; each tile's luminance noise is its high-pass
(the tile less a 9-pixel box blur), relative to its mean, in linear light. The model's print of a
neutral of the stock is swept in half stops for the exposure whose print luminance is the
tile's; at the scan's pitch its per-pixel luminance noise is the stock's grain chain
(`argent_bake.grain`: rmsGranularity48um, the density response and r(p), interpolated in log-log
between the research's pitches) through the Endura print. It prints both and their ratio, which
is the grain amount at which the model's print would show the scan's grain.

What the scans cannot tell: the scanner, its tone curve, sharpening and noise reduction, and the
JPEG's quality are unknown, so the ratio is the amount for a scan rendered like this print at
that luminance (inference). docs/research/film.md section 4.3 reads it.

The scans used there are Ivanova, Williamson and Henderson's, shot and scanned by Dmitri
Tcherbadji (Analog.Cafe), figshare doi:10.6084/m9.figshare.21803304, CC BY 4.0; they are not in
the repository.

    cd bake && PYTHONPATH=. ../.venv/bin/python tools/scan_grain.py portra400=/path/portra400_135_1.jpg ...
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image

from argent_bake.grain import PIXEL_RATIO, density_response, net_density, print_noise
from argent_bake.negative import MID_GRAY, dye_amounts
from argent_bake.paper import paper_named
from argent_bake.printing import GRAY_TARGET, Printer, calibrate
from argent_bake.profile import load_profile

TILE = 128


def pixel_ratio(long_side: int) -> float:
    """r(p) at any output size, interpolated in log-log between the research's sizes."""
    sizes = np.array(sorted(PIXEL_RATIO))
    ratios = np.array([PIXEL_RATIO[s] for s in sizes])
    return float(np.exp(np.interp(np.log(long_side), np.log(sizes), np.log(ratios))))


def box(a: np.ndarray, r: int) -> np.ndarray:
    c = np.cumsum(np.cumsum(np.pad(a, ((r + 1, r), (r + 1, r)), mode="edge"), 0), 1)
    n = 2 * r + 1
    return (c[n:, n:] - c[:-n, n:] - c[n:, :-n] + c[:-n, :-n]) / n ** 2


def sky_tiles(path: Path, count: int = 4) -> tuple[list, int]:
    """[(mean linear luminance, relative high-pass noise)] of the flattest upper-third tiles, and the long side."""
    image = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0
    linear = np.where(image <= 0.04045, image / 12.92, ((image + 0.055) / 1.055) ** 2.4)
    y = linear @ np.array([0.2126, 0.7152, 0.0722])
    high = y - box(y, 4)
    tiles = []
    for top in range(0, y.shape[0] // 3 - TILE, TILE // 2):
        for left in range(0, y.shape[1] - TILE, TILE // 2):
            tile = y[top:top + TILE, left:left + TILE]
            mean = tile.mean()
            flatness = np.abs(box(tile, 16) - mean).mean() / mean
            tiles.append((flatness, mean, high[top:top + TILE, left:left + TILE].std() / mean))
    tiles.sort()
    return [(m, n) for _, m, n in tiles[:count]], max(y.shape)


def model_noise(profile, printer, filtration, luminance: float, long_side: int) -> float:
    """The print's per-pixel relative luminance noise, amount 1, at the exposure printing to `luminance`."""
    stops = np.arange(-3.0, 4.0 + 1e-9, 0.25)
    rows = [print_noise(profile, printer, filtration, s,
                        profile.grain_rms48 * pixel_ratio(long_side) * density_response(net_density(profile, s)))
            for s in stops]
    lum = np.array([r.luminance for r in rows])
    noise = np.array([r.relative_luminance_sigma for r in rows])
    return float(np.interp(luminance, lum, noise))


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parents[1] / "stocks"
    for argument in argv[1:]:
        name, path = argument.split("=", 1)
        profile = load_profile(root / f"{name}.json")
        printer = Printer(paper_named(profile.paper), profile.dyes, profile.base)
        filtration = calibrate(printer, dye_amounts(profile, np.full(3, MID_GRAY)), GRAY_TARGET)
        tiles, long_side = sky_tiles(Path(path))
        for luminance, noise in tiles:
            predicted = model_noise(profile, printer, filtration, luminance, long_side)
            print(f"{name:12s} {Path(path).name}: {long_side} px, sky at linear luminance {luminance:.3f}, "
                  f"scan noise {100 * noise:.2f}%, model at amount 1 {100 * predicted:.2f}%, ratio {noise / predicted:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
