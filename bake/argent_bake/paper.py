"""Print papers: load a paper profile from `papers/` and invert its curves into dye amounts.

A paper sheet prints Status A characteristic curves of the whole print, spectral
sensitivities of the three layers, and unit-peak dye spectra. The curves include the
unexposed paper's own density and every dye's absorption in every channel, so this module
first fits a base spectrum whose Status A density equals the sheet's minimum density
(three knots at the Status A centroid wavelengths, flat beyond the outer ones), then
solves each curve sample for the non-negative dye amounts over that base that read as the
printed densities, with the projected Newton of `densitometry.py` under Status A weights.

The net amounts become the paper's curves, which keeps the print model paper-relative:
paper white is (1, 1, 1). Phase 1 found that dividing by the paper white equals Bradford
adaptation to it within dE2000 0.01 on neutrals (measured), so no structural change was
needed in `printing.py`. The base spectrum stays on the model for an optional absolute
render that the bake does not use.
"""

import json
from importlib.resources import as_file, files
from pathlib import Path

import numpy as np

from .densitometry import invert_curves, status_density, status_weights
from .printing import PaperModel
from .spectral import WAVELENGTHS, blackbody, daylight, resample_hold, resample_log

PAPERS_DIR = files("argent_bake").joinpath("papers")
if not PAPERS_DIR.is_dir():
    PAPERS_DIR = Path(__file__).resolve().parents[1] / "papers"
LAYERS = ("red", "green", "blue")
DYES = ("cyan", "magenta", "yellow")
SCHEMAS = (1, 2)
CURVE_FALL_TOLERANCE = 0.05


class PaperError(ValueError):
    """The paper profile cannot be used: unfinished, malformed, or physically wrong."""


def illuminant_from(spec, name: str, what: str) -> np.ndarray:
    """A light named in a profile: {"kind": "blackbody" or "daylight", "kelvin": T}."""
    try:
        kind = spec["kind"]
        kelvin = float(spec["kelvin"])
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise PaperError(f"paper {name}: {what} needs a kind and a kelvin") from error
    if not np.isfinite(kelvin) or kelvin <= 0:
        raise PaperError(f"paper {name}: {what}.kelvin must be finite and positive")
    if kind not in ("blackbody", "daylight"):
        raise PaperError(f"paper {name}: {what}.kind must be blackbody or daylight, not {kind!r}")
    try:
        with np.errstate(over="ignore", invalid="ignore", divide="ignore"):
            spectrum = blackbody(kelvin) if kind == "blackbody" else daylight(kelvin)
    except ValueError as error:
        raise PaperError(f"paper {name}: {what}: {error}") from error
    if not np.all(np.isfinite(spectrum)) or np.any(spectrum < 0) or not np.any(spectrum > 0):
        raise PaperError(f"paper {name}: {what} must produce a finite, non-negative light spectrum")
    return spectrum


def weight_centroids(weights: np.ndarray, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """The mean wavelength of each status channel's spectral product."""
    return (wl[:, None] * weights).sum(axis=0) / weights.sum(axis=0)


def three_knot_density(knot_wl: np.ndarray, knot_density: np.ndarray, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """A spectral density through three knots, linear between them and flat beyond the outer ones."""
    order = np.argsort(knot_wl)
    return np.interp(wl, knot_wl[order], knot_density[order])


def fit_base(minimum_density: np.ndarray, weights: np.ndarray):
    """The unexposed paper's spectral density: three knots solved so its status density equals `minimum_density`.

    Returns (spectrum, knot wavelengths, knot densities). Newton with a finite-difference
    Jacobian; the problem is three equations in three unknowns and nearly linear.
    """
    knot_wl = weight_centroids(weights)
    knots = np.asarray(minimum_density, dtype=float).copy()
    for _ in range(50):
        residual = status_density(three_knot_density(knot_wl, knots), weights) - minimum_density
        if np.max(np.abs(residual)) < 1e-12:
            break
        jacobian = np.empty((3, 3))
        for k in range(3):
            step = np.zeros(3)
            step[k] = 1e-6
            jacobian[:, k] = (status_density(three_knot_density(knot_wl, knots + step), weights)
                              - minimum_density - residual) / 1e-6
        knots = knots - np.linalg.solve(jacobian, residual)
    return three_knot_density(knot_wl, knots), knot_wl, knots


def load_paper(source) -> PaperModel:
    """Read a paper profile from a JSON path or an already-parsed dict."""
    if isinstance(source, (str, Path)):
        try:
            data = json.loads(Path(source).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise PaperError(f"cannot read paper {source}: {error}") from error
    else:
        data = source

    if not isinstance(data, dict):
        raise PaperError("paper profile must be a JSON object")
    name = data.get("id", "<unnamed>")
    status = data.get("status", "")
    if status == "placeholder":
        raise PaperError(f"paper {name} is a placeholder")
    schema = data.get("schema", 1)
    if schema not in SCHEMAS:
        raise PaperError(f"paper {name}: schema {schema} is not supported; this bake reads schema 1 and 2")

    def table(section: str, key: str, expected: int, nulls: bool = False) -> np.ndarray:
        try:
            raw = list(data[section][key])
            values = np.asarray([np.nan if v is None else float(v) for v in raw], dtype=float)
        except (KeyError, TypeError, ValueError, OverflowError) as error:
            raise PaperError(f"paper {name}: {section}.{key} is missing or not numeric") from error
        if values.ndim != 1 or values.size != expected:
            raise PaperError(f"paper {name}: {section}.{key} has {values.size} values, expected {expected}")
        present = np.asarray([v is not None for v in raw])
        if not np.all(np.isfinite(values[present])):
            raise PaperError(f"paper {name}: {section}.{key} has values that are not finite")
        if not nulls and not present.all():
            raise PaperError(f"paper {name}: {section}.{key} must not contain null")
        return values

    def axis(section: str, key: str) -> np.ndarray:
        try:
            values = np.asarray(data[section][key], dtype=float)
        except (KeyError, TypeError, ValueError, OverflowError) as error:
            raise PaperError(f"paper {name}: {section}.{key} is missing or not numeric") from error
        if values.ndim != 1 or values.size < 2 or not np.all(np.isfinite(values)) or not np.all(np.diff(values) > 0):
            raise PaperError(f"paper {name}: {section}.{key} must be finite and strictly increasing")
        return values

    sens_wl = axis("spectralSensitivity", "wavelengths")
    with np.errstate(over="ignore"):
        sensitivity = np.stack(
            [resample_log(sens_wl, table("spectralSensitivity", layer, sens_wl.size, nulls=True))
             for layer in LAYERS], axis=1)
    if not np.all(np.isfinite(sensitivity)) or not np.all(sensitivity.max(axis=0) > 0):
        raise PaperError(f"paper {name}: each layer needs finite, positive spectral sensitivity on the bake's wavelength range")

    curves_section = data.get("characteristicCurves")
    if not isinstance(curves_section, dict):
        raise PaperError(f"paper {name}: characteristicCurves is missing")
    densitometry = curves_section.get("densitometry", "statusA")
    if densitometry not in ("statusA", "statusM"):
        raise PaperError(f"paper {name}: characteristicCurves.densitometry must be statusA or statusM")
    log_exposure = axis("characteristicCurves", "logExposure")
    status_curves = np.stack([table("characteristicCurves", layer, log_exposure.size) for layer in LAYERS], axis=1)
    if np.any(status_curves < 0):
        raise PaperError(f"paper {name}: characteristic curves contain negative density")
    if np.any(np.diff(status_curves, axis=0) < -CURVE_FALL_TOLERANCE):
        raise PaperError(f"paper {name}: characteristic curves must not fall as exposure rises")

    dye_wl = axis("dyeDensity", "wavelengths")
    dyes = np.stack([resample_hold(dye_wl, table("dyeDensity", dye, dye_wl.size)) for dye in DYES], axis=1)
    if np.any(dyes < 0):
        raise PaperError(f"paper {name}: dye densities contain negative values")
    peaks = dyes.max(axis=0)
    if np.any(peaks <= 0):
        raise PaperError(f"paper {name}: a dye has no density on the bake's wavelength range")
    dyes = dyes / peaks

    weights = status_weights("A" if densitometry == "statusA" else "M")
    try:
        minimum = np.asarray(data["minimumDensity"][densitometry], dtype=float)
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise PaperError(f"paper {name}: minimumDensity.{densitometry} is missing or not numeric") from error
    if minimum.shape != (3,) or not np.all(np.isfinite(minimum)) or np.any(minimum < 0):
        raise PaperError(f"paper {name}: minimumDensity.{densitometry} must be three non-negative, finite densities")
    base, _, _ = fit_base(minimum, weights)
    amounts, residuals = invert_curves(status_curves, base, dyes, weights)

    medium = data.get("medium", "reflection")
    if medium not in ("reflection", "transmission"):
        raise PaperError(f"paper {name}: medium must be reflection or transmission")
    aim = None
    if medium == "transmission":
        if densitometry != "statusA":
            raise PaperError(f"paper {name}: transmission needs Status A curves")
        try:
            aim = np.asarray(data["labAimDensity"], dtype=float)
        except (KeyError, TypeError, ValueError, OverflowError) as error:
            raise PaperError(f"paper {name}: transmission needs three labAimDensity values") from error
        if aim.shape != (3,) or not np.all(np.isfinite(aim)) or not np.all(aim > minimum):
            raise PaperError(f"paper {name}: labAimDensity must be three finite densities above the minimum")
    elif "labAimDensity" in data:
        raise PaperError(f"paper {name}: labAimDensity is only supported for transmission")

    return PaperModel(
        name=name,
        sensitivity=sensitivity,
        log_exposure=log_exposure,
        curves=amounts,
        dyes=dyes,
        enlarger=illuminant_from(data.get("enlarger"), name, "enlarger"),
        viewing=illuminant_from(data.get("viewing"), name, "viewing"),
        base=base,
        status_curves=status_curves,
        densitometry=densitometry,
        inversion_residual=float(np.max(np.abs(residuals))),
        display_name=data.get("displayName", name),
        status=status,
        medium=medium,
        lab_aim_density=aim,
    )


def paper_named(name: str) -> PaperModel:
    """The print paper a profile names: the synthetic paper, or a JSON profile in `papers/`."""
    from . import synthetic
    if name == synthetic.PAPER_NAME:
        return synthetic.paper()
    profiles = {p.name[:-5]: p for p in PAPERS_DIR.iterdir() if p.name.endswith(".json") and p.is_file()} \
        if PAPERS_DIR.is_dir() else {}
    path = profiles.get(name) if isinstance(name, str) else None
    if path is None:
        known = ", ".join([synthetic.PAPER_NAME] + sorted(profiles))
        raise ValueError(f"no print paper named {name!r}; known: {known}")
    with as_file(path) as profile_path:
        paper = load_paper(profile_path)
    if paper.name != name:
        raise ValueError(f"paper file {path.name} says its id is {paper.name!r}, not {name!r}")
    return paper
