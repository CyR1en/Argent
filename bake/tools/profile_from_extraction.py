#!/usr/bin/env python3
"""Write the stock and paper profiles from the reviewed datasheet extractions.

The reviewed CSVs live in references/datasheets/reviewed-extraction/<stock>/{char,sens,dye}.csv.
That folder is git-ignored because the datasheets are (c) Kodak Alaris and are read locally
only; the numbers digitized from them are the project's own and go into bake/stocks/<id>.json
and bake/papers/kodak-endura-premier.json, which this tool writes. Run it again whenever the
extraction changes so the profiles stay reproducible:

    .venv/bin/python bake/tools/profile_from_extraction.py

It applies the corrections the review asked for, prints the numbers it checks for every
profile, validates each one, and exits non-zero if a check fails. Nothing here loads a
profile into the bake; that is the loader's job.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

import numpy as np

DIGITIZED = "2026-10-06"
PAPER_ID = "kodak-endura-premier"
LAYERS = ("red", "green", "blue")
# The column each layer reads in the sensitivity CSVs: the red-sensitive layer forms the
# cyan dye, the green-sensitive layer the magenta dye, the blue-sensitive layer the yellow dye.
LAYER_COLUMNS = {"red": "logS_cyan_layer", "green": "logS_magenta_layer", "blue": "logS_yellow_layer"}
CURVE_COLUMNS = {"red": "D_R", "green": "D_G", "blue": "D_B"}

# Portra 400 is the grain anchor: rms granularity per layer at a 48 micrometre aperture,
# a guess plus or minus 30 percent (docs/M3-research.md section 3). The other stocks scale it.
GRAIN_ANCHOR = ("0.0050", "0.0055", "0.0132")
GRAIN_BASIS = (
    "printGrainIndex is the sheet's 135 format value at 4.4X, 8.8X and 17.8X (null where the sheet "
    "prints none or under 25); relativeSigma is 10^(dPGI / 100.8) against Portra 400 (inference); "
    "rmsGranularity48um is the Portra 400 anchor of 0.0050, 0.0055, 0.0132 scaled by relativeSigma, "
    "plus or minus 30 percent, docs/M3-research.md section 3; the anchor agrees with DxO's measurement of "
    "scanned Portra 160NC, with the diffuse RMS granularity other makers print for ISO 400 colour negatives, "
    "and with freely licensed scans, docs/research/film.md section 4.3")
HALATION_ANCHOR = "0.015"
HALATION_BASIS = (
    "strength and green share a guess, docs/M3-research.md section 4, the strength inside what the 0.10 mm "
    "base's reflection geometry allows for Kodak's undercoat densities (0.0035 to 0.19); radius the render "
    "kernel's scale, whose weights follow that geometry, docs/research/film.md section 4.4")
# Fitted by tools/fit_couplers.py so each layer's Status M gamma ratio at mid-scale, separation over
# white light, meets the anchor of the stock's class (docs/research/film.md section 4.2).
COUPLER_ANCHORS = {
    "natural": ("natural: FUJICOLOR NPH 400's green and blue, the Kodak films' red", (1.36, 1.27, 0.97)),
    "between": ("halfway between natural and KODAK MAX 400", (1.36, 1.44, 1.13)),
    # Portra 800 above Portra 400, below Ektar, as Kodak's 2023 catalogue and 2017 brochure rank them
    # (docs/research/film-sim/bakelook.md section 4; tools/fit_couplers.py PORTRA_800_STEP).
    "0.62 of the way": ("0.62 of the way from natural to KODAK MAX 400", (1.36, 1.481, 1.168)),
    "KODAK HD 400": ("KODAK HD 400", (1.38, 1.81, 1.33)),
    "KODAK MAX 400": ("KODAK MAX 400", (1.36, 1.61, 1.29)),
}
COUPLER_BASIS = (
    "no sheet publishes interimage; fitted (bake/tools/fit_couplers.py) so the layers' Status M gamma ratios "
    "at mid-scale, separation over white light, meet those Fuji's EP1693702A1 (2005, Table 3) measured on "
    "commercial films, for the stock's class (inference), each layer's inhibition split between the other "
    "two as Kodak's US6620580B2 and US5314792A describe (inference); docs/research/film.md section 4.2")
# The sheet's "Judging negative exposures" table: Status M red densities of a normally exposed and
# processed negative. The paper gray scale's lightest step has a nominal density of 0.1 (Kodak's
# product page for the KODAK Paper Gray Scale, read 2026-10-07); the forehead rows are a guide only.
JUDGING_SOURCE = (
    "Status M red of a normally exposed and processed negative: a KODAK Gray Card (gray side), the lightest "
    "step of a KODAK Paper Gray Scale (nominal density 0.1), and the highest diffuse density on a normally "
    "lit forehead of light and of dark complexion, which the sheet gives as a guide only")

# The lab's tone stage each stock prints through (docs/research/film-sim/print.md section 4): the three Portras
# fail US5300381 FIG. 2's tone on ENDURA Premier, as does every paper their own sheets name, and a stage built from
# FIG. 2 passes every check; Ektar 100, Gold 200 and UltraMax 400 stay optical prints on ENDURA Premier.
PRINT_STAGES = {"portra-400": "US5300381 FIG. 2", "portra-160": "US5300381 FIG. 2", "portra-800": "US5300381 FIG. 2"}

COMMON_LIMITS = (
    "Kodak calls the curves typical, representative of production coatings and not of any one roll. "
    "The Status M red, green and blue densities are what the sheet prints: they include "
    "cross-absorption and the orange mask, so they are not layer densities. The sheet gives no "
    "per-dye spectra, only the midscale neutral and minimum density totals, so dyeDensity holds those "
    "two curves and the bake has to unmix them. The couplers are fitted to gamma ratios published for "
    "commercial films of the stock's class, not measured on this stock. Grain is anchored on the Print "
    "Grain Index and checked against published scans; halation's strength is a guess inside what the base "
    "allows. No roll of this stock was shot or scanned for Argent. No push or pull processing."
)

STOCKS = [
    {
        "key": "portra-400",
        "couplerAnchor": "between", "couplers": [[0.0, 0.58, 0.14], [0.845, 0.0, 0.923], [0.08, 0.364, 0.0]], "file": "portra400.json", "id": "kodak-portra-400",
        "displayName": "Portra 400", "modelledFilm": "Kodak Portra 400", "boxSpeed": 400,
        "publication": "E-4050", "edition": "2025-01",
        "url": "https://kodakprofessional.com/sites/default/files/2025-07/e4050.pdf",
        "char": "char.csv", "logHRef": -1.44,
        "grayCard": (0.77, 0.87), "grayCardPage": "p3",
        "whiteStep": (1.13, 1.23), "forehead": ((1.08, 1.18), (0.93, 1.03)),
        "pgi": (37, 59, 89), "relativeSigma": "1.00", "halationFactor": "1",
        "labelErrors": None,
        "notes": "Digitized from the Kodak E-4050 datasheet of January 2025, whose plots equal the February 2016 edition.",
        "sensGaps": {},
        "sensFixes": {},
    },
    {
        "key": "portra-160",
        "couplerAnchor": "natural", "couplers": [[0.0, 0.572, 0.155], [0.543, 0.0, 0.689], [0.018, 0.085, 0.0]], "file": "portra160.json", "id": "kodak-portra-160",
        "displayName": "Portra 160", "modelledFilm": "Kodak Portra 160", "boxSpeed": 160,
        "publication": "E-4051", "edition": "2025-01",
        "url": "https://kodakprofessional.com/sites/default/files/2025-07/e4051.pdf",
        "char": "char_tick-calibration.csv", "logHRef": -1.051,
        "grayCard": (0.79, 0.89), "grayCardPage": "p3",
        "whiteStep": (1.15, 1.25), "forehead": ((1.10, 1.20), (0.95, 1.05)),
        "pgi": (28, 50, 79), "relativeSigma": "0.81", "halationFactor": "0.85",
        "labelErrors": "The sensitivity plot's y axis label reads 20 for 2.0. The characteristic plot's frame and its y ticks disagree by 0.024 D.",
        "notes": ("Digitized from the Kodak E-4051 datasheet of January 2025. The characteristic plot's frame and its y ticks "
                  "disagree by 0.024 D and the tick reading was kept (the frame reading is 0.007 to 0.023 D lower), so the "
                  "densities carry plus or minus 0.024 D. The sheet's MTF plot is not used."),
        "sensGaps": {},
        "sensFixes": {},
    },
    {
        "key": "portra-800",
        "couplerAnchor": "0.62 of the way", "couplers": [[0.0, 0.567, 0.146], [0.885, 0.0, 0.974], [0.104, 0.442, 0.0]], "file": "portra800.json", "id": "kodak-portra-800",
        "displayName": "Portra 800", "modelledFilm": "Kodak Portra 800", "boxSpeed": 800,
        "publication": "E-4040", "edition": "2025-01",
        "url": "https://kodakprofessional.com/sites/default/files/2025-07/e4040.pdf",
        "char": "char_EI800.csv", "logHRef": -1.74,
        "grayCard": (0.75, 0.95), "grayCardPage": "p3",
        "whiteStep": (1.00, 1.20), "forehead": ((0.95, 1.25), (0.75, 1.10)),
        "pgi": (48, 70, 99), "relativeSigma": "1.28", "halationFactor": "1.3",
        "labelErrors": "The x axis labels -2.0 and -3.0 of the EI 800 characteristic plot are transposed; the ticks were read in order.",
        "notes": ("Digitized from the Kodak E-4040 datasheet of January 2025. Only the EI 800 curves are here; the sheet also "
                  "prints push 1 (EI 1600) and push 2 (EI 3200) characteristic curves, which are not in 1.0. The sheet's MTF "
                  "plot is not used."),
        "sensGaps": {},
        "sensFixes": {},
    },
    {
        "key": "ektar-100",
        "couplerAnchor": "KODAK HD 400", "couplers": [[0.0, 0.658, 0.155], [1.167, 0.0, 1.381], [0.151, 0.757, 0.0]], "file": "ektar100.json", "id": "kodak-ektar-100",
        "displayName": "Ektar 100", "modelledFilm": "Kodak Ektar 100", "boxSpeed": 100,
        "publication": "E-4046", "edition": "2025-01",
        "url": "https://www.kodakprofessional.com/sites/default/files/2025-07/e4046.pdf",
        "char": "char.csv", "logHRef": -0.84,
        "grayCard": (0.77, 0.87), "grayCardPage": "p3",
        "whiteStep": (1.13, 1.23), "forehead": ((1.08, 1.18), (0.93, 1.03)),
        "pgi": (None, 38, 66), "relativeSigma": "0.60", "halationFactor": "0.7",
        "labelErrors": None,
        "notes": ("Digitized from the Kodak E-4046 datasheet of January 2025. The sheet prints the Print Grain Index at 4.4X as "
                  "under 25, which is null here. The dye curves are plotted from 405 to 685 nm; the minimum density curve "
                  "alone starts at 400 nm and that one point is dropped so both arrays share a grid. The sheet's MTF plot "
                  "is not used."),
        "sensGaps": {},
        "sensFixes": {},
    },
    {
        "key": "gold-200",
        "couplerAnchor": "KODAK MAX 400", "couplers": [[0.0, 0.534, 0.142], [1.018, 0.0, 1.134], [0.187, 0.781, 0.0]], "file": "gold200.json", "id": "kodak-gold-200",
        "displayName": "Gold 200", "modelledFilm": "Kodak Gold 200", "boxSpeed": 200,
        "publication": "E-7022", "edition": "2023-06",
        "url": "https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/E7022%20Gold%20tech%20sheet.pdf",
        "char": "char.csv", "logHRef": -1.14,
        "grayCard": (0.85, 1.05), "grayCardPage": "p2",
        "whiteStep": (1.25, 1.45), "forehead": ((1.15, 1.45), (0.90, 1.30)),
        "pgi": (44, 64, None), "relativeSigma": "1.15", "halationFactor": "1",
        "labelErrors": ("The x axis labels use overbars for the minus sign, which the PDF text layer drops; the ticks were read "
                        "in order. The Print Grain Index row prints 4.4X twice; the 64 belongs to 8.8X. The sensitivity curves "
                        "are stored as 4 pt wide tiles and were chained by their endpoints."),
        "notes": ("Digitized from the Kodak E-7022 datasheet of June 2023. The blue curve dips 0.031 D below its running "
                  "maximum near log H -2.67; it is printed that way on the sheet and kept. The red-sensitive layer's "
                  "sensitivity runs along the plot floor from 455 to 485 nm, where the true value is below the plotted "
                  "range, so those entries are null. The reviewed CSV left the green-sensitive layer blank at 425 nm by "
                  "mistake; the review supplies 1.080 and this tool writes it. The sheet has no MTF plot and no Print "
                  "Grain Index at 17.8X."),
        "sensGaps": {"red": (455, 460, 465, 470, 475, 480, 485)},
        "sensFixes": {("green", 425): 1.080},
    },
    {
        "key": "ultramax-400",
        "couplerAnchor": "KODAK MAX 400", "couplers": [[0.0, 0.559, 0.151], [0.98, 0.0, 1.106], [0.174, 0.724, 0.0]], "file": "ultramax400.json", "id": "kodak-ultramax-400",
        "displayName": "UltraMax 400", "modelledFilm": "Kodak UltraMax 400", "boxSpeed": 400,
        "publication": "E-7023", "edition": "2016-02",
        "url": "https://business.kodakmoments.com/sites/default/files/files/resources/E7023_max_400.pdf",
        "char": "char.csv", "logHRef": -1.44,
        "grayCard": (0.80, 1.00), "grayCardPage": "p3",
        "whiteStep": (1.20, 1.40), "forehead": ((1.10, 1.40), (0.85, 1.25)),
        "pgi": (46, None, None), "relativeSigma": "1.23", "halationFactor": "1",
        "labelErrors": None,
        "notes": ("Digitized from the Kodak E-7023 datasheet of February 2016 (titled ULTRA MAX 400), the newest edition "
                  "found. The sheet prints one Print Grain Index value, 46 at 4.4X, and has no MTF plot. The dye curves "
                  "are plotted from 405 to 700 nm."),
        "sensGaps": {},
        "sensFixes": {},
    },
]

PAPER = {
    "key": "paper-endura-premier", "file": "kodak-endura-premier.json", "id": PAPER_ID,
    "displayName": "Kodak Professional Endura Premier",
    "publication": "E-4070", "edition": "2017-12",
    "url": "https://business.kodakmoments.com/sites/default/files/files/products/e4070.pdf",
    "process": "RA-4, 95 F (35 C), 45 s; sensitometric exposure 0.5 s; Status A densitometry",
    "dyePeaks": {"cyan": 650, "magenta": 550, "yellow": 445},
    "enlarger": {"kind": "blackbody", "kelvin": 3200},
    "viewing": {"kind": "daylight", "kelvin": 5003},
    "notes": ("Digitized from the Kodak E-4070 datasheet of December 2017, the paper every one of the six film sheets "
              "names. Status A curves for a 0.5 s sensitometric exposure; the sheet does not say what light the "
              "sensitometer used, so the enlarger here is a stand-in and lab balance acts on a relative scale. Past "
              "D-max the curves fall by up to 0.020 D (red, from log H -0.40 to -0.15); that is printed on the sheet "
              "and kept, so a loader that wants a monotonic curve has to clip it. The dye curves are the sheet's own "
              "unit-peak curves and read 0.998, 1.000 and 1.000 on the 5 nm grid. No granularity and no MTF on "
              "the sheet."),
}

MONOTONIC_TOLERANCE = 0.002


class CheckError(Exception):
    """A profile failed validation. The message says which check and by how much."""


# Reading the reviewed CSVs.


class Table:
    """One reviewed CSV: its provenance header, its x axis and its columns with NaN for blanks."""

    def __init__(self, path: Path):
        self.path = path
        header: list[str] = []
        rows: list[list[str]] = []
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("#"):
                    header.append(line[1:].strip())
                else:
                    rows.append(line.rstrip("\n").split(","))
        self.header = header
        names = rows[0]
        body = rows[1:]
        self.x = np.array([float(row[0]) for row in body])
        self.columns: dict[str, np.ndarray] = {}
        for index, name in enumerate(names[1:], 1):
            cells = [row[index] if index < len(row) else "" for row in body]
            self.columns[name] = np.array([float(cell) if cell != "" else np.nan for cell in cells])

    def header_number(self, pattern: str) -> float | None:
        text = " ".join(self.header)
        match = re.search(pattern, text)
        return float(match.group(1)) if match else None

    def agreement(self) -> float | None:
        """The largest difference to the earlier independent extraction, over all columns."""
        values = [float(v) for v in re.findall(r"max ([0-9.]+), mean", " ".join(self.header))]
        return max(values) if values else None

    def tick_residual(self) -> float | None:
        return self.header_number(r"max tick residual ([0-9.]+) pt")

    def tool(self) -> str:
        match = re.search(r"extracted with (pypdf [0-9.]+)", " ".join(self.header))
        return match.group(1) if match else "pypdf"


def trimmed_domain(columns: list[np.ndarray]) -> tuple[int, int]:
    """First and last index where any column has a value."""
    present = np.any(~np.isnan(np.stack(columns)), axis=0)
    indices = np.flatnonzero(present)
    return int(indices[0]), int(indices[-1]) + 1


def common_domain(columns: list[np.ndarray]) -> tuple[int, int]:
    """First and last index where every column has a value."""
    present = np.all(~np.isnan(np.stack(columns)), axis=0)
    indices = np.flatnonzero(present)
    return int(indices[0]), int(indices[-1]) + 1


def check_grid(x: np.ndarray, step: float, what: str) -> None:
    if x.size < 2 or not np.all(np.diff(x) > 0):
        raise CheckError(f"{what}: axis is not strictly increasing")
    if not np.allclose(np.diff(x), step, atol=1e-6):
        raise CheckError(f"{what}: axis step is not {step}")


# Building the pieces of a profile.


def build_sensitivity(table: Table, fixes: dict, gaps: dict, what: str) -> tuple[np.ndarray, dict[str, np.ndarray]]:
    check_grid(table.x, 5.0, f"{what} sensitivity")
    layers = {layer: table.columns[LAYER_COLUMNS[layer]].copy() for layer in LAYERS}
    for (layer, wavelength), value in fixes.items():
        index = int(np.flatnonzero(np.isclose(table.x, wavelength))[0])
        if not np.isnan(layers[layer][index]):
            raise CheckError(f"{what}: {layer} at {wavelength} nm is not blank, the fix does not apply")
        layers[layer][index] = value
    start, stop = trimmed_domain(list(layers.values()))
    wavelengths = table.x[start:stop]
    layers = {layer: values[start:stop] for layer, values in layers.items()}
    # Nulls are allowed outside a layer's own plotted domain and at documented interior gaps only.
    for layer, values in layers.items():
        present = np.flatnonzero(~np.isnan(values))
        interior = np.isnan(values[present[0]:present[-1] + 1])
        gap = set(wavelengths[present[0]:present[-1] + 1][interior].astype(int).tolist())
        documented = set(gaps.get(layer, ()))
        if gap != documented:
            raise CheckError(f"{what}: {layer} sensitivity has undocumented blanks at {sorted(gap - documented)} nm")
    return wavelengths, layers


def build_curves(table: Table, what: str) -> tuple[np.ndarray, dict[str, np.ndarray]]:
    check_grid(table.x, 0.05, f"{what} characteristic curves")
    curves = {layer: table.columns[CURVE_COLUMNS[layer]] for layer in LAYERS}
    start, stop = common_domain(list(curves.values()))
    log_exposure = table.x[start:stop]
    curves = {layer: values[start:stop] for layer, values in curves.items()}
    for layer, values in curves.items():
        if np.any(np.isnan(values)):
            raise CheckError(f"{what}: {layer} characteristic curve has a blank inside its domain")
    return log_exposure, curves


def build_spectra(table: Table, names: dict[str, str], what: str) -> tuple[np.ndarray, dict[str, np.ndarray], list[str]]:
    """Density spectra share one grid, so the domain is the one every curve covers."""
    check_grid(table.x, 5.0, f"{what} dye density")
    spectra = {key: table.columns[column] for key, column in names.items()}
    start, stop = common_domain(list(spectra.values()))
    dropped = []
    for key, values in spectra.items():
        for index in np.flatnonzero(~np.isnan(values)):
            if index < start or index >= stop:
                dropped.append(f"{key} {int(table.x[index])} nm {values[index]:.4f}")
    wavelengths = table.x[start:stop]
    spectra = {key: values[start:stop] for key, values in spectra.items()}
    for key, values in spectra.items():
        if np.any(np.isnan(values)):
            raise CheckError(f"{what}: {key} spectrum has a blank inside its domain")
        if np.any(values < 0):
            raise CheckError(f"{what}: {key} spectrum has negative density")
    return wavelengths, spectra, dropped


def largest_dip(values: np.ndarray) -> tuple[float, float, np.ndarray]:
    """How far a curve falls below its running maximum, and where."""
    dips = np.maximum.accumulate(values) - values
    index = int(np.argmax(dips))
    return float(dips[index]), index, dips


def check_monotonic(log_exposure: np.ndarray, curves: dict[str, np.ndarray], allowed: dict[str, float], what: str) -> dict[str, tuple[float, float]]:
    result = {}
    for layer, values in curves.items():
        dip, index, _ = largest_dip(values)
        result[layer] = (dip, float(log_exposure[index]))
        if dip > MONOTONIC_TOLERANCE + 1e-9 and dip > allowed.get(layer, 0.0) + 1e-9:
            raise CheckError(f"{what}: {layer} curve falls {dip:.4f} D below its running maximum at log H {log_exposure[index]:.2f}")
    return result


def interpolate(x: np.ndarray, y: np.ndarray, at: float) -> float:
    return float(np.interp(at, x, y))


def exposure_for_density(log_exposure: np.ndarray, curve: np.ndarray, density: float) -> float | None:
    """The log H where a rising curve first reaches a density, by linear interpolation."""
    above = np.flatnonzero(curve >= density)
    if above.size == 0 or above[0] == 0:
        return None
    i = int(above[0])
    fraction = (density - curve[i - 1]) / (curve[i] - curve[i - 1])
    return float(log_exposure[i - 1] + fraction * (log_exposure[i] - log_exposure[i - 1]))


def peak(wavelengths: np.ndarray, values: np.ndarray) -> tuple[int, float]:
    index = int(np.nanargmax(values))
    return int(wavelengths[index]), float(values[index])


def decimal(text: str) -> Decimal:
    return Decimal(text)


def scaled(anchor: str, factor: str, places: str) -> float:
    return float((decimal(anchor) * decimal(factor)).quantize(Decimal(places), rounding=ROUND_HALF_UP))


def method_text(char: Table, sens: Table, dye: Table, kind: str) -> str:
    residual = max(t.tick_residual() or 0.0 for t in (char, sens, dye))
    density_unit = "D" if kind == "stock" else "Status A density"
    return (
        f"vector paths of the datasheet PDF read with {char.tool()} through the project's own content stream "
        f"interpreter, axes calibrated by least squares on the labelled tick lines (largest tick residual "
        f"{residual:.3f} pt), curves resampled by linear interpolation every 0.05 log H and 5 nm; an earlier "
        f"independent extraction with PyMuPDF agrees within {char.agreement():.4f} {density_unit} on the "
        f"characteristic curves, {sens.agreement():.4f} log S on the sensitivities and {dye.agreement():.4f} D "
        f"on the dye densities"
    )


# Writing JSON with compact arrays and fixed decimals.


def fitted_exposure_matrix(path: Path) -> dict:
    """The profile's exposureMatrix as it stands, kept across a rewrite: it is fitted to reflectances
    (tools/fit_exposure_matrix.py), not extracted from the sheet."""
    if not path.exists():
        return {}
    section = json.loads(path.read_text(encoding="utf-8")).get("exposureMatrix")
    if section is None:
        return {}
    return {"exposureMatrix": {"matrix": [[Fixed(v, 6) for v in row] for row in section["matrix"]], "basis": section["basis"]}}


class Fixed:
    """A number written with a fixed count of decimals so the files diff cleanly."""

    def __init__(self, value: float, decimals: int):
        self.value = float(value)
        self.decimals = decimals

    def text(self) -> str:
        return f"{self.value:.{self.decimals}f}"


def fixed_list(values, decimals: int) -> list:
    return [None if value is None or (isinstance(value, float) and np.isnan(value)) else Fixed(value, decimals)
            for value in values]


def emit(value, indent: int = 0) -> str:
    pad = "  " * indent
    if isinstance(value, dict):
        if not value:
            return "{}"
        inner = ",\n".join(f"{pad}  {json.dumps(key)}: {emit(item, indent + 1)}" for key, item in value.items())
        return "{\n" + inner + "\n" + pad + "}"
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(emit(item, indent + 1) for item in value) + "]"
    if isinstance(value, Fixed):
        return value.text()
    if isinstance(value, bool) or value is None:
        return json.dumps(value)
    if isinstance(value, (int, np.integer)):
        return str(int(value))
    if isinstance(value, (float, np.floating)):
        return repr(float(value))
    return json.dumps(value, ensure_ascii=False)


def write_json(path: Path, data: dict) -> None:
    text = emit(data) + "\n"
    json.loads(text)  # the file must be plain JSON
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def read_back(path: Path, section: str, key: str) -> np.ndarray:
    data = json.loads(path.read_text(encoding="utf-8"))
    return np.array([np.nan if v is None else v for v in data[section][key]], dtype=float)


def assert_round_trip(path: Path, section: str, key: str, source: np.ndarray, decimals: int) -> None:
    written = read_back(path, section, key)
    if written.shape != source.shape:
        raise CheckError(f"{path.name}: {section}.{key} changed length on write")
    both = ~np.isnan(source)
    if not np.array_equal(np.isnan(written), ~both):
        raise CheckError(f"{path.name}: {section}.{key} changed where it is null on write")
    if np.max(np.abs(written[both] - source[both])) > 0.5 * 10 ** -decimals + 1e-12:
        raise CheckError(f"{path.name}: {section}.{key} did not survive rounding")


# The stock profiles.


def make_stock(spec: dict, extraction: Path, out_dir: Path) -> None:
    folder = extraction / spec["key"]
    char = Table(folder / spec["char"])
    sens = Table(folder / "sens.csv")
    dye = Table(folder / "dye.csv")
    # The checks are on the film's sheet, so they name the film; the stock's own name is data.
    name = spec["modelledFilm"]

    log_exposure, curves = build_curves(char, name)
    sens_wavelengths, layers = build_sensitivity(sens, spec["sensFixes"], spec["sensGaps"], name)
    dye_wavelengths, spectra, dropped = build_spectra(
        dye, {"midscaleNeutral": "D_midscale_neutral", "minimumDensity": "D_min"}, name)

    # Checks, printed so the run is its own record.
    print(f"== {name} ({spec['id']}) from {char.path.name}, sens.csv, dye.csv")
    print(f"   characteristic curves: log H {log_exposure[0]:.2f} to {log_exposure[-1]:.2f}, {log_exposure.size} points")
    print(f"   sensitivity: {int(sens_wavelengths[0])} to {int(sens_wavelengths[-1])} nm; dye density: "
          f"{int(dye_wavelengths[0])} to {int(dye_wavelengths[-1])} nm")
    if dropped:
        print(f"   dye density points outside the shared domain, dropped: {'; '.join(dropped)}")
    dmin = {layer: float(curves[layer][0]) for layer in LAYERS}
    print(f"   D-min (curve left end, log H {log_exposure[0]:.2f}) R/G/B: " + " / ".join(f"{dmin[l]:.4f}" for l in LAYERS))
    at_ref = {layer: interpolate(log_exposure, curves[layer], spec["logHRef"]) for layer in LAYERS}
    print(f"   density at Log H Ref {spec['logHRef']} R/G/B: " + " / ".join(f"{at_ref[l]:.4f}" for l in LAYERS))
    low, high = spec["grayCard"]
    centre = (low + high) / 2
    at_centre = exposure_for_density(log_exposure, curves["red"], centre)
    inside = low <= at_ref["red"] <= high
    print(f"   gray-card red window {low:.2f} to {high:.2f}: red reaches the centre {centre:.2f} at log H "
          f"{at_centre:.3f}; red at Log H Ref is {'inside' if inside else 'outside'} the window")
    peaks = {layer: peak(sens_wavelengths, layers[layer]) for layer in LAYERS}
    print("   sensitivity peak R/G/B: " + " / ".join(f"{peaks[l][0]} nm ({peaks[l][1]:.3f})" for l in LAYERS))
    gap = spectra["midscaleNeutral"] - spectra["minimumDensity"]
    gap_index = int(np.argmin(gap))
    print(f"   midscale minus minimum density: smallest gap {gap[gap_index]:.4f} D at {int(dye_wavelengths[gap_index])} nm")
    if gap[gap_index] <= 0:
        raise CheckError(f"{name}: midscale neutral is not above minimum density everywhere")
    allowed = {"blue": 0.031} if spec["key"] == "gold-200" else {}
    dips = check_monotonic(log_exposure, curves, allowed, name)
    print("   largest fall below the running maximum R/G/B: " + " / ".join(
        f"{dips[l][0]:.4f} D at log H {dips[l][1]:.2f}" for l in LAYERS)
          + (" (Gold 200 blue toe dip, printed on the sheet, allowed)" if allowed else ""))
    for section_name, wavelengths in (("sensitivity", sens_wavelengths), ("dye density", dye_wavelengths)):
        if not np.all(np.diff(wavelengths) > 0):
            raise CheckError(f"{name}: {section_name} wavelengths are not strictly increasing")

    pgi = spec["pgi"]
    pgi_anchor = STOCKS[0]["pgi"]
    deltas = [a - b for a, b in zip(pgi, pgi_anchor) if a is not None and b is not None]
    derived_sigma = 10 ** (float(np.mean(deltas)) / 100.8) if deltas else 1.0
    print(f"   Print Grain Index {pgi}: relative sigma from the formula {derived_sigma:.3f}, stored {spec['relativeSigma']}")
    rms = [scaled(anchor, spec["relativeSigma"], "0.0001") for anchor in GRAIN_ANCHOR]
    strength = scaled(HALATION_ANCHOR, spec["halationFactor"], "0.00001")
    print(f"   rms granularity at 48 um R/G/B: {rms[0]:.4f} / {rms[1]:.4f} / {rms[2]:.4f}; halation strength {strength}")

    notes = spec["notes"] + " " + COMMON_LIMITS
    if not inside:
        notes += (f" Red density at Log H Ref {spec['logHRef']} is {at_ref['red']:.3f}, outside the sheet's gray-card "
                  f"window of {low:.2f} to {high:.2f}; the red curve meets the window centre at log H {at_centre:.2f}.")

    source = {
        "publication": spec["publication"], "edition": spec["edition"], "url": spec["url"],
        "digitized": DIGITIZED, "method": method_text(char, sens, dye, "stock"),
    }
    if spec["labelErrors"]:
        source["labelErrors"] = spec["labelErrors"]

    data = {
        "schema": 2,
        "id": spec["id"],
        "displayName": spec["displayName"],
        "modelledFilm": name,
        "manufacturer": "Kodak",
        "boxSpeed": spec["boxSpeed"],
        "status": "datasheet",
        "notes": notes,
        "source": source,
        "spectralSensitivity": {
            "wavelengths": [int(w) for w in sens_wavelengths],
            **{layer: fixed_list(layers[layer], 4) for layer in LAYERS},
        },
        "characteristicCurves": {
            "densitometry": "statusM",
            "logExposure": fixed_list(log_exposure, 2),
            **{layer: fixed_list(curves[layer], 4) for layer in LAYERS},
            "logExposureReference": spec["logHRef"],
        },
        "dyeDensity": {
            "wavelengths": [int(w) for w in dye_wavelengths],
            "midscaleNeutral": fixed_list(spectra["midscaleNeutral"], 4),
            "minimumDensity": fixed_list(spectra["minimumDensity"], 4),
        },
        "grayCard": {
            "redDensity": [Fixed(low, 2), Fixed(high, 2)],
            "whiteStepRedDensity": [Fixed(v, 2) for v in spec["whiteStep"]],
            "foreheadRedDensity": {
                "lightComplexion": [Fixed(v, 2) for v in spec["forehead"][0]],
                "darkComplexion": [Fixed(v, 2) for v in spec["forehead"][1]],
            },
            "source": f"{spec['publication']} {spec['grayCardPage']}, " + JUDGING_SOURCE,
        },
        "couplers": {
            "interLayer": [[Fixed(v, 3) for v in row] for row in spec["couplers"]],
            "gammaRatios": [Fixed(v, 2 if round(v, 2) == v else 3) for v in COUPLER_ANCHORS[spec["couplerAnchor"]][1]],
            "anchor": COUPLER_ANCHORS[spec["couplerAnchor"]][0],
            "basis": COUPLER_BASIS,
        },
        **fitted_exposure_matrix(Path(__file__).resolve().parents[1] / "stocks" / spec["file"]),
        "halation": {"strength": strength, "greenShare": 0.25, "radiusMicrometres": 180, "basis": HALATION_BASIS},
        "grain": {
            "printGrainIndex": list(pgi),
            "relativeSigma": Fixed(float(decimal(spec["relativeSigma"])), 2),
            "rmsGranularity48um": fixed_list(rms, 4),
            "basis": GRAIN_BASIS,
        },
        "paper": PAPER_ID,
        "printStage": PRINT_STAGES.get(spec["key"]),
        "correctionLUT": None,
    }
    path = out_dir / "stocks" / spec["file"]
    write_json(path, data)
    for layer in LAYERS:
        assert_round_trip(path, "spectralSensitivity", layer, layers[layer], 4)
        assert_round_trip(path, "characteristicCurves", layer, curves[layer], 4)
    assert_round_trip(path, "characteristicCurves", "logExposure", log_exposure, 2)
    assert_round_trip(path, "dyeDensity", "midscaleNeutral", spectra["midscaleNeutral"], 4)
    assert_round_trip(path, "dyeDensity", "minimumDensity", spectra["minimumDensity"], 4)
    print(f"   wrote {path}")


# The paper profile.


def make_paper(spec: dict, extraction: Path, out_dir: Path) -> None:
    folder = extraction / spec["key"]
    char = Table(folder / "char.csv")
    sens = Table(folder / "sens.csv")
    dye = Table(folder / "dye.csv")
    name = spec["displayName"]

    log_exposure, curves = build_curves(char, name)
    sens_wavelengths, layers = build_sensitivity(sens, {}, {}, name)
    dye_wavelengths, dyes, dropped = build_spectra(
        dye, {"cyan": "D_cyan", "magenta": "D_magenta", "yellow": "D_yellow"}, name)

    print(f"== {name} ({spec['id']}) from char.csv, sens.csv, dye.csv")
    print(f"   characteristic curves: log H {log_exposure[0]:.2f} to {log_exposure[-1]:.2f}, {log_exposure.size} points")
    print(f"   sensitivity: {int(sens_wavelengths[0])} to {int(sens_wavelengths[-1])} nm; dye density: "
          f"{int(dye_wavelengths[0])} to {int(dye_wavelengths[-1])} nm")
    if dropped:
        print(f"   dye density points outside the shared domain, dropped: {'; '.join(dropped)}")
    dmin = {layer: float(curves[layer][0]) for layer in LAYERS}
    print(f"   Status A D-min (curve left end, log H {log_exposure[0]:.2f}) R/G/B: "
          + " / ".join(f"{dmin[l]:.4f}" for l in LAYERS)
          + "; lowest point R/G/B: " + " / ".join(f"{float(np.min(curves[l])):.4f}" for l in LAYERS))
    dmax = {layer: (float(np.max(curves[layer])), float(log_exposure[int(np.argmax(curves[layer]))])) for layer in LAYERS}
    print("   Status A D-max R/G/B: " + " / ".join(f"{dmax[l][0]:.4f} at log H {dmax[l][1]:.2f}" for l in LAYERS))
    peaks = {layer: peak(sens_wavelengths, layers[layer]) for layer in LAYERS}
    print("   sensitivity peak R/G/B: " + " / ".join(f"{peaks[l][0]} nm ({peaks[l][1]:.3f})" for l in LAYERS))
    for dye_name, expected in spec["dyePeaks"].items():
        wavelength, value = peak(dye_wavelengths, dyes[dye_name])
        print(f"   {dye_name} dye peak {value:.4f} at {wavelength} nm (expected 1.000 at {expected} nm)")
        if wavelength != expected or abs(value - 1.0) > 0.002:
            raise CheckError(f"{name}: {dye_name} dye peak is {value:.4f} at {wavelength} nm, expected 1.000 at {expected} nm")
    # The sheet's curves fall past D-max; the roll-off is printed and kept. Allow it per layer.
    allowed = {layer: 0.021 for layer in LAYERS}
    dips = check_monotonic(log_exposure, curves, allowed, name)
    print("   largest fall below the running maximum R/G/B: " + " / ".join(
        f"{dips[l][0]:.4f} D at log H {dips[l][1]:.2f}" for l in LAYERS)
          + " (shoulder roll-off past D-max, printed on the sheet, allowed)")
    for layer in LAYERS:
        toe = curves[layer][:int(np.argmax(curves[layer]))]
        toe_dip, index, _ = largest_dip(toe)
        if toe_dip > MONOTONIC_TOLERANCE + 1e-9:
            raise CheckError(f"{name}: {layer} curve falls {toe_dip:.4f} D before D-max at log H {log_exposure[index]:.2f}")

    data = {
        "schema": 2,
        "id": spec["id"],
        "displayName": name,
        "manufacturer": "Kodak",
        "status": "datasheet",
        "notes": spec["notes"],
        "source": {
            "publication": spec["publication"], "edition": spec["edition"], "url": spec["url"],
            "digitized": DIGITIZED, "method": method_text(char, sens, dye, "paper"),
        },
        "process": spec["process"],
        "spectralSensitivity": {
            "wavelengths": [int(w) for w in sens_wavelengths],
            **{layer: fixed_list(layers[layer], 4) for layer in LAYERS},
        },
        "characteristicCurves": {
            "densitometry": "statusA",
            "logExposure": fixed_list(log_exposure, 2),
            **{layer: fixed_list(curves[layer], 4) for layer in LAYERS},
        },
        "dyeDensity": {
            "wavelengths": [int(w) for w in dye_wavelengths],
            "cyan": fixed_list(dyes["cyan"], 4),
            "magenta": fixed_list(dyes["magenta"], 4),
            "yellow": fixed_list(dyes["yellow"], 4),
        },
        "minimumDensity": {"statusA": [Fixed(dmin[layer], 3) for layer in LAYERS]},
        "enlarger": spec["enlarger"],
        "viewing": spec["viewing"],
    }
    path = out_dir / "papers" / spec["file"]
    write_json(path, data)
    for layer in LAYERS:
        assert_round_trip(path, "spectralSensitivity", layer, layers[layer], 4)
        assert_round_trip(path, "characteristicCurves", layer, curves[layer], 4)
    assert_round_trip(path, "characteristicCurves", "logExposure", log_exposure, 2)
    for dye_name in ("cyan", "magenta", "yellow"):
        assert_round_trip(path, "dyeDensity", dye_name, dyes[dye_name], 4)
    print(f"   wrote {path}")


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--extraction", type=Path, default=repo / "references" / "datasheets" / "reviewed-extraction",
                        help="folder with the reviewed CSVs, one subfolder per stock and one for the paper")
    parser.add_argument("--out", type=Path, default=repo / "bake",
                        help="the bake folder; profiles go to its stocks/ and papers/ subfolders")
    parser.add_argument("--only", nargs="*", default=None,
                        help="keys to write (portra-400, ..., paper-endura-premier); default all")
    args = parser.parse_args(argv)
    if not args.extraction.is_dir():
        print(f"no reviewed extraction at {args.extraction}", file=sys.stderr)
        return 2
    wanted = set(args.only) if args.only else None
    try:
        for spec in STOCKS:
            if wanted is None or spec["key"] in wanted:
                make_stock(spec, args.extraction, args.out)
        if wanted is None or PAPER["key"] in wanted:
            make_paper(PAPER, args.extraction, args.out)
    except CheckError as error:
        print(f"check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
