"""Neutral digital stock: camera colour with a pleasing tone curve, no grain, no halation.

Unlike the film stocks, Neutral does not pass through a negative emulsion or optical print
paper. Its Negative LUT is the identity in log-encoded scene-linear Rec. 2020 space, and
its Print LUT applies a luminance-preserving tone curve with moderate midtone contrast,
open shadows, and a soft highlight roll-off, plus hue-preserving gamut roll-off when a
bright saturated channel approaches display white.

Because 1 stop of print exposure or lab balance shifts the Print LUT input by
log10(2) / (exposurePerUnit * densityRange), setting exposurePerUnit = (1, 1, 1) and
densityRange = encoding.range * log10(2) makes every stop of print exposure, lab balance,
or PrintTone burn/dodge an exact exposure stop in scene-linear Rec. 2020 before the tone
curve.
"""

import json
import math
from pathlib import Path

import numpy as np

from . import __version__
from .bake import (MANIFEST_FILE, NEGATIVE_BINARY, NEGATIVE_FILE, PRINT_BINARY, PRINT_FILE, SCHEMA,
                   BakeResult, _resolve_output, _rounded, _stock_output)
from .cube import write_binary, write_cube
from .encoding import LogEncoding
from .negative import FILM_LOG_ENCODING, MID_GRAY

STOCK_ID = "argent-neutral"
DISPLAY_NAME = "Neutral"
STATUS = "digital"
BOX_SPEED = 100.0

REC2020_LUMA = np.array([0.2627, 0.6780, 0.0593], dtype=np.float64)

# Tone curve parameters (scene-linear Y -> display-linear Y in [0, 1], anchored at T(0.18) = 0.18):
# - CONTRAST > 1 gives moderate midtone punch (~18 L*/EV around mid-gray vs 15.3 linear, 22.9 Portra 400).
# - SHADOW_TOE blends deep shadows back toward slope 1 so shadows stay open without lifting black.
# - SHOULDER_POWER shapes the asymptotic highlight roll-off toward 1.0 with no hard clip.
# - GAMUT_KNEE keeps in-gamut colours at exact camera chromaticity and smoothly desaturates only
#   highlights whose peak channel nears or exceeds 1.0, along constant hue and luminance.
CONTRAST = 1.35
SHADOW_TOE = 0.035
SHOULDER_POWER = 1.6
GAMUT_KNEE = 0.85


def _raw_tone_curve(luminance: np.ndarray) -> np.ndarray:
    y = np.maximum(luminance, 0.0)
    midtone = y * ((y + SHADOW_TOE) / (MID_GRAY + SHADOW_TOE)) ** (CONTRAST - 1.0)
    return midtone / (1.0 + midtone ** SHOULDER_POWER) ** (1.0 / SHOULDER_POWER)


def _solve_mid_gray_gain() -> float:
    low, high = 0.5, 2.0
    for _ in range(80):
        mid = 0.5 * (low + high)
        if float(_raw_tone_curve(np.array(mid * MID_GRAY))) < MID_GRAY:
            low = mid
        else:
            high = mid
    return 0.5 * (low + high)


_MID_GRAY_GAIN = _solve_mid_gray_gain()


def tone_curve(luminance) -> np.ndarray:
    """Map scene-linear luminance (>= 0) to display-linear luminance in [0, 1] with T(0.18) = 0.18."""
    return _raw_tone_curve(_MID_GRAY_GAIN * np.asarray(luminance, dtype=np.float64))


def develop(rgb) -> np.ndarray:
    """Develop scene-linear Rec. 2020 RGB with exact camera colour and the Neutral tone curve."""
    scene = np.maximum(np.asarray(rgb, dtype=np.float64), 0.0)
    y_in = scene @ REC2020_LUMA
    y_out = tone_curve(y_in)
    scale = np.where(y_in > 1e-12, y_out / np.maximum(y_in, 1e-12), 0.0)
    scaled = scene * scale[..., None]

    # Hue- and luminance-preserving highlight roll-off toward neutral (y_out, y_out, y_out)
    # only when the brightest channel approaches or exceeds 1.0.
    peak = np.max(scaled, axis=-1)
    headroom = np.maximum(1.0 - y_out, 1e-12)
    ratio = np.maximum(peak - y_out, 0.0) / headroom
    span = 1.0 - GAMUT_KNEE
    excess = np.maximum(ratio - GAMUT_KNEE, 0.0)
    rolled = np.where(ratio <= GAMUT_KNEE, ratio, GAMUT_KNEE + span * (excess / (excess + span)))
    chroma_scale = np.where(ratio > GAMUT_KNEE, rolled / np.maximum(ratio, 1e-12), 1.0)
    out = y_out[..., None] + chroma_scale[..., None] * (scaled - y_out[..., None])
    return np.clip(out, 0.0, 1.0)


def _decode_grid(grid: np.ndarray, encoding: LogEncoding) -> np.ndarray:
    stops = grid * encoding.range - encoding.stops_below_mid_gray
    return encoding.mid_gray * (2.0 ** stops)


def bake_neutral(out_dir, size: int = 65, encoding: LogEncoding | None = None) -> BakeResult:
    """Bake the Neutral digital stock into `out_dir` using the standard schema-2 stock contract."""
    out = Path(out_dir)
    target = _resolve_output(out)
    if target.exists() and Path.cwd().resolve().is_relative_to(target):
        raise ValueError(f"refusing to rebake {target}: it is the current working directory or contains it")

    encoding = encoding if encoding is not None else FILM_LOG_ENCODING
    density_range = round(encoding.range * math.log10(2.0), 6)
    exposure_per_unit = np.ones(3, dtype=np.float64)
    filtration = np.zeros(3, dtype=np.float64)

    axis = np.linspace(0.0, 1.0, size, dtype=np.float64)
    b, g, r = np.meshgrid(axis, axis, axis, indexing="ij")
    grid_u = np.stack([r, g, b], axis=-1)

    negative_rows = grid_u.reshape(-1, 3)
    print_rows = develop(_decode_grid(grid_u, encoding)).reshape(-1, 3)

    manifest = {
        "schema": SCHEMA,
        "id": STOCK_ID,
        "displayName": DISPLAY_NAME,
        "modelledFilm": None,
        "status": STATUS,
        "boxSpeed": BOX_SPEED,
        "densityRange": density_range,
        "negative": {
            "file": NEGATIVE_FILE,
            "binary": NEGATIVE_BINARY,
            "size": size,
            "logEncoding": {
                "stopsBelowMidGray": encoding.stops_below_mid_gray,
                "stopsAboveMidGray": encoding.stops_above_mid_gray,
                "midGray": encoding.mid_gray,
            },
        },
        "print": {
            "file": PRINT_FILE,
            "binary": PRINT_BINARY,
            "size": size,
            "exposurePerUnit": _rounded(exposure_per_unit),
        },
        "grain": None,
        "halation": None,
        "bake": {
            "tool": "argent-bake",
            "version": __version__,
            "kind": "neutral",
            "toneCurve": {
                "contrast": CONTRAST,
                "shadowToe": SHADOW_TOE,
                "shoulderPower": SHOULDER_POWER,
                "gamutKnee": GAMUT_KNEE,
                "midGray": MID_GRAY,
            },
        },
    }

    with _stock_output(target) as staging:
        write_cube(str(staging / NEGATIVE_FILE), size, f"Argent {STOCK_ID} negative", negative_rows)
        write_binary(str(staging / NEGATIVE_BINARY), size, negative_rows)
        write_cube(str(staging / PRINT_FILE), size, f"Argent {STOCK_ID} print", print_rows)
        write_binary(str(staging / PRINT_BINARY), size, print_rows)
        (staging / MANIFEST_FILE).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    return BakeResult(out, size, density_range, filtration, exposure_per_unit)
