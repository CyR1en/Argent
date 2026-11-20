"""Bake a stock profile into the two LUTs and the manifest the app loads.

The output folder is the contract with `Stock.load` in ArgentCore, manifest schema 2:

    stock.json       manifest: identity (the stock's own name and the film it models), box
                     speed, density range, LUT files, log encoding, exposure per unit dye, and
                     the bake's provenance
    negative.cube    log-encoded scene-linear Rec. 2020 RGB to dye amounts / density range
    negative.lut3d   the same table in the binary format
    print.cube       dye amounts / density range to display-linear Rec. 2020 RGB
    print.lut3d      the same table in the binary format

Scene mid-gray at the box speed prints as a neutral 0.18 with no lab balance. That is
the daylight reference, and the Swift tests check it on whatever this writes.
"""

import ctypes
import errno
import json
import os
import sys
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from shutil import copy2, copymode, copytree, rmtree
from uuid import uuid4

import numpy as np

from . import __version__
from .cube import write_binary, write_cube
from .encoding import LogEncoding
from .grain import grain_table
from .negative import (MID_GRAY, SHOULDER_START_STOPS, SHOULDER_WIDTH_STOPS, bake_negative, dye_amounts,
                       encoding_for, gray_card_red_density, iso5800_speed, mid_gray_log_exposure, uses_modeled_shoulder)
from .paper import paper_named  # noqa: F401  (re-exported: the command line and the tests look it up here)
from .print_stage import stage_for
from .printing import PaperModel, Printer, bake_print, calibrate, exposure_per_unit
from .profile import MEASURED_STATUSES, StockProfile

SCHEMA = 2
NEGATIVE_FILE = "negative.cube"
NEGATIVE_BINARY = "negative.lut3d"
PRINT_FILE = "print.cube"
PRINT_BINARY = "print.lut3d"
MANIFEST_FILE = "stock.json"
_STOCK_FILES = {NEGATIVE_FILE, NEGATIVE_BINARY, PRINT_FILE, PRINT_BINARY, MANIFEST_FILE}
_AT_FDCWD = -100
_RENAME_EXCHANGE = 2
_RENAME_SWAP = 2


@dataclass(frozen=True)
class BakeResult:
    directory: Path
    size: int
    density_range: float
    filtration: np.ndarray  # log10 paper exposure offsets of the daylight reference
    exposure_per_unit: np.ndarray  # log10 paper exposure per unit of each dye at mid-gray


def _rounded(values, places: int = 6) -> list:
    return [round(float(v), places) for v in np.asarray(values).ravel()]


def _exchange_directories(staging: Path, out: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    source, target = os.fsencode(staging), os.fsencode(out)
    try:
        if sys.platform == "linux":
            rename = libc.renameat2
            rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
            args = (_AT_FDCWD, source, _AT_FDCWD, target, _RENAME_EXCHANGE)
        elif sys.platform == "darwin":
            rename = libc.renamex_np
            rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
            args = (source, target, _RENAME_SWAP)
        else:
            raise AttributeError
    except AttributeError:
        raise OSError(errno.ENOSYS, "atomic directory exchange is unavailable", staging, None, out) from None

    rename.restype = ctypes.c_int
    if rename(*args) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), staging, None, out)


@contextmanager
def _stock_output(out: Path):
    """Prepare a sibling directory, then publish it once all writes have succeeded."""
    out.parent.mkdir(parents=True, exist_ok=True)
    staging = out.with_name(f".argent-bake-{uuid4().hex}")
    staging.mkdir()
    try:
        if out.exists():
            for entry in out.iterdir():
                if entry.name in _STOCK_FILES:
                    if entry.is_dir():
                        raise IsADirectoryError(f"stock file is a directory: {entry}")
                    continue
                if not entry.is_symlink() and entry.is_dir():
                    copytree(entry, staging / entry.name, symlinks=True)
                else:
                    copy2(entry, staging / entry.name, follow_symlinks=False)
            copymode(out, staging)

        yield staging

        if out.exists():
            _exchange_directories(staging, out)
        else:
            staging.rename(out)
    finally:
        rmtree(staging, ignore_errors=True)


def bake_stock(profile: StockProfile, paper: PaperModel, out_dir, size: int = 65,
               encoding: LogEncoding | None = None) -> BakeResult:
    if profile.paper != paper.name:
        raise ValueError(f"profile {profile.id} prints onto {profile.paper!r}, not {paper.name!r}")

    out = Path(out_dir)
    target = out.resolve()
    if target.exists() and Path.cwd().resolve().is_relative_to(target):
        raise ValueError(f"refusing to rebake {target}: it is the current working directory or contains it")

    encoding = encoding if encoding is not None else encoding_for(profile)
    negative = bake_negative(profile, size, encoding)
    printer = Printer(paper, profile.dyes, profile.base, stage=stage_for(profile, paper))
    gray_amounts = dye_amounts(profile, np.full(3, MID_GRAY))
    filtration = calibrate(printer, gray_amounts)
    per_unit = exposure_per_unit(printer, gray_amounts)
    print_lut = bake_print(printer, size, negative.density_range, filtration)

    negative_rows = negative.lut.reshape(-1, 3)
    print_rows = print_lut.reshape(-1, 3)

    manifest = {
        "schema": SCHEMA,
        "id": profile.id,
        "displayName": profile.display_name,
        "modelledFilm": profile.modelled_film,
        "status": profile.status,
        "boxSpeed": profile.box_speed,
        "densityRange": negative.density_range,
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
            "exposurePerUnit": _rounded(per_unit),
        },
        "grain": grain_table(profile, negative.density_range) or None,
        "halation": profile.halation,
        "bake": {
            "tool": "argent-bake",
            "version": __version__,
            "paper": paper.name,
            "printStage": profile.print_stage,
            "daylightFiltration": _rounded(filtration),
            "midGrayLogExposure": round(mid_gray_log_exposure(profile.box_speed), 6),
            "grayCardRedDensity": round(gray_card_red_density(profile), 4),
            "grayCardWindow": None if profile.gray_card is None else list(profile.gray_card),
            "iso5800Speed": round(iso5800_speed(profile), 1)
            if profile.status in MEASURED_STATUSES and profile.speed_reference else None,
            "midGrayAmounts": _rounded(gray_amounts),
            "negativeModel": {
                **(profile.negative_model or {}),
                "inversionResidual": float(f"{profile.inversion_residual:.3e}"),
                "units": "the Negative LUT holds amounts of three unit-peak dyes divided by densityRange; "
                         "the base and mask spectrum is applied in the Print LUT",
            },
        },
    }
    if uses_modeled_shoulder(profile):
        manifest["bake"]["highlightShoulder"] = {"startStops": SHOULDER_START_STOPS, "widthStops": SHOULDER_WIDTH_STOPS}
    elif profile.has_published_shoulder:
        manifest["bake"]["highlightShoulder"] = {"source": "published"}
    if profile.capture_illuminant_kelvin is not None:
        manifest["bake"]["captureIlluminantKelvin"] = profile.capture_illuminant_kelvin
    if paper.lab_aim_density is not None:
        manifest["bake"]["labAimDensity"] = {"statusA": _rounded(paper.lab_aim_density)}
        manifest["modelledPrint"] = paper.display_name
    with _stock_output(target) as staging:
        write_cube(str(staging / NEGATIVE_FILE), size, f"Argent {profile.id} negative", negative_rows)
        write_binary(str(staging / NEGATIVE_BINARY), size, negative_rows)
        write_cube(str(staging / PRINT_FILE), size, f"Argent {profile.id} print", print_rows)
        write_binary(str(staging / PRINT_BINARY), size, print_rows)
        (staging / MANIFEST_FILE).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return BakeResult(out, size, negative.density_range, filtration, per_unit)
