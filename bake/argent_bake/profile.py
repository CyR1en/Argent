"""Stock profiles: load, validate, and resample onto the bake's wavelength grid.

A profile is JSON in the units a datasheet prints them in: log10 sensitivity against
wavelength, Status M density against log10 lux-seconds, spectral density against
wavelength. Schema 2 (see `stocks/portra400.json`) carries the sheet's two density plots,
Midscale Neutral and Minimum Density, and the loader unmixes their difference into three
dyes (`unmixing.py`); a synthetic or fitted profile may instead give explicit cyan,
magenta and yellow spectra. In both cases the loader then inverts the characteristic
curves, which are status densities of the whole negative, into amounts of those dyes
(`densitometry.py`), and the rest of the bake works in dye amounts.

Null entries in the sensitivity arrays mean the layer is outside its plotted domain and
does not respond there. Density spectra are extended beyond their wavelength range by
holding the end values.
"""

import json
import math
import re
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np

from .densitometry import invert_curves, status_density, status_weights
from .spectral import WAVELENGTHS, resample_hold, resample_log
from .unmixing import unmix

LAYERS = ("red", "green", "blue")  # the layer each curve belongs to, by the light it records
DYES = ("cyan", "magenta", "yellow")  # the dye each layer forms, in the same order
SCHEMAS = (1, 2)
STOCK_ID_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
MEASURED_STATUSES = ("datasheet", "fitted")
SOURCED_STATUSES = (*MEASURED_STATUSES, "approximation")
CURVE_FALL_TOLERANCE = 0.05  # density a curve may fall by between samples before the profile is refused

# The sheets plot every curve to the same edge, about 2.09 log H above the bake's mid-gray, and each is
# still rising there at 0.3 to 0.75 per log H: the edge of the plot, not a shoulder (docs/research/
# film-sim/scans.md section 4.1). Each curve is extended past its last plotted point as a straight line
# at its last plotted slope, read as the least-squares slope of the last TOP_SLOPE_POINTS points (the
# last 0.25 log H on every sheet), which averages out the digitizing's few thousandths per point. No
# roll-off is added: its shape would need a source the sheets do not give. The line runs
# EXTENSION_LOG_H past the plot; beyond that the amounts are held flat. This is the
# reference sensitometry. The film LUT adds a shoulder when reading these curves.
TOP_SLOPE_POINTS = 6
EXTENSION_LOG_H = 4.5


# The published systems a lab's tone stage may be built from (argent_bake/print_stage.py).
PRINT_STAGES = ("US5300381 FIG. 1", "US5300381 FIG. 2")

class ProfileError(ValueError):
    """The profile cannot be baked: unfinished, malformed, or physically wrong."""


@dataclass(frozen=True)
class PrintVariant:
    id: str
    display_name: str
    paper: str


@dataclass(frozen=True)
class StockProfile:
    id: str
    display_name: str
    manufacturer: str
    status: str
    box_speed: float
    paper: str
    # Relative spectral sensitivity of the red-, green-, and blue-sensitive layers, linear, on WAVELENGTHS.
    sensitivity: np.ndarray  # (n, 3)
    # Characteristic curves as the sheet prints them: status density of the whole negative
    # (base, mask and cross-absorption included) against log10 lux-seconds.
    log_exposure: np.ndarray  # (m,)
    curves: np.ndarray  # (m, 3)
    # Spectral density of the cyan, magenta, and yellow dyes, peak 1.0, on WAVELENGTHS.
    dyes: np.ndarray  # (n, 3)
    # Spectral density of the unexposed negative (base and mask), on WAVELENGTHS. Zeros if the profile has none.
    base: np.ndarray  # (n,)
    # Amounts of the three dyes that read as `curves` through the status densitometer over `base`.
    amount_curves: np.ndarray  # (m, 3)
    inversion_residual: float  # largest status density residual of that inversion
    # couplers[j][k]: log10 exposure that layer j loses per unit amount layer k develops
    # beyond what it would at the same exposure as j. The diagonal is ignored.
    couplers: np.ndarray  # (3, 3)
    gray_card: tuple | None  # (low, high) Status M red density of a normally exposed gray card
    log_exposure_reference: float | None  # the sheet's printed Log H Ref, informational
    negative_model: dict | None  # how the dyes were obtained: method, fit quality, cross-talk
    # RMS granularity per layer at a 48 micrometre aperture and net density 1.0, red, green,
    # blue; a guess until scans exist (docs/M3-research.md section 3). None when not given.
    grain_rms48: np.ndarray | None = None
    # Halation as the profile gives it: strength (energy returned), the green share and the
    # radius in film-plane micrometres; a guess (docs/M3-research.md section 4). None when absent.
    halation: dict | None = None
    # The sheet's other Status M red windows for a normally exposed negative: the lightest step of
    # a KODAK Paper Gray Scale, and a normally lit forehead of light and of dark complexion (a guide
    # only, the sheet says). None when the profile does not give them.
    white_step: tuple | None = None
    forehead: dict | None = None
    # The film the stock models in full, for the descriptive line ("After Kodak Portra 400: ...");
    # `display_name` is the name the app shows. None for a stock modelled on
    # no film, such as the synthetic one.
    modelled_film: str | None = None
    # The curves above hold the sheet's plotted points and then the straight-line extension; the
    # last plotted log H, and each curve's Status M slope there (density per log H), that the line follows.
    plotted_to: float | None = None
    top_slopes: np.ndarray | None = None
    # Relative layer exposure per unit of each Rec. 2020 primary, rows summing to one, fitted to measured
    # reflectances (`tools/fit_exposure_matrix.py`). None: the bake upsamples through a smooth basis.
    exposure_matrix: np.ndarray | None = None
    # A lab's tone stage before the paper, built from a published film/paper system ("US5300381 FIG. 2"), or None
    # for an optical print (docs/research/film-sim/print.md section 4).
    print_stage: str | None = None
    # Relative-density charts can match the shape but not the absolute fog of the spectral plot.
    density_offset: np.ndarray | None = None
    speed_reference: bool = True
    densitometry: str = "statusM"
    capture_illuminant_kelvin: float | None = None
    has_published_shoulder: bool = False
    print_variants: tuple[PrintVariant, ...] = ()

    def with_print_variant(self, variant: PrintVariant) -> "StockProfile":
        return replace(self, id=variant.id, display_name=variant.display_name, paper=variant.paper,
                       print_stage=None, print_variants=())


def _number(value, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProfileError(f"profile {name}: must be a finite number")
    try:
        number = float(value)
    except OverflowError as error:
        raise ProfileError(f"profile {name}: must be a finite number") from error
    if not math.isfinite(number):
        raise ProfileError(f"profile {name}: must be a finite number")
    return number


def _window(section: dict, key: str, name: str) -> tuple | None:
    """A [low, high] density window from `section[key]`, or None when the key is absent."""
    if key not in section:
        return None
    try:
        low, high = (_number(v, f"{name}: grayCard {key}") for v in section[key])
    except (TypeError, ValueError) as error:
        raise ProfileError(f"profile {name}: grayCard {key} must be [low, high]") from error
    if not low < high:
        raise ProfileError(f"profile {name}: grayCard {key} must be [low, high] with low below high")
    return (low, high)


def load_profile(source) -> StockProfile:
    """Read a profile from a JSON path or an already-parsed dict."""
    if isinstance(source, (str, Path)):
        try:
            data = json.loads(Path(source).read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ProfileError(f"cannot read profile {source}: {error}") from error
        if not isinstance(data, dict):
            raise ProfileError(f"cannot read profile {source}: expected a JSON object")
    else:
        data = source

    name = data.get("id")
    if not isinstance(name, str) or not STOCK_ID_PATTERN.fullmatch(name):
        location = f"profile {source}" if isinstance(source, (str, Path)) else "profile"
        raise ProfileError(f"{location}: id must be a non-empty string of lowercase ASCII letters and digits, "
                           "optionally separated by hyphens")
    status = data.get("status", "")
    if status == "placeholder":
        raise ProfileError(
            f"profile {name} is a placeholder: its curves are empty until the datasheet is digitized")
    schema = data.get("schema", 1)
    if schema not in SCHEMAS:
        raise ProfileError(f"profile {name}: schema {schema} is not supported; this bake reads schema 1 and 2")
    measured = status in MEASURED_STATUSES

    def section(key: str) -> dict:
        value = data.get(key)
        if not isinstance(value, dict):
            raise ProfileError(f"profile {name}: {key} is missing")
        return value

    def table(section_name: str, key: str, expected: int, nulls: bool = False) -> np.ndarray:
        try:
            raw = list(data[section_name][key])
            values = np.asarray([np.nan if v is None else float(v) for v in raw], dtype=float)
        except (KeyError, TypeError, ValueError) as error:
            raise ProfileError(f"profile {name}: {section_name}.{key} is missing or not numeric") from error
        if values.ndim != 1 or values.size == 0:
            raise ProfileError(f"profile {name}: {section_name}.{key} must be a non-empty list of numbers")
        if values.size != expected:
            raise ProfileError(f"profile {name}: {section_name}.{key} has {values.size} values, expected {expected}")
        present = np.asarray([v is not None for v in raw])
        if not np.all(np.isfinite(values[present])):
            raise ProfileError(f"profile {name}: {section_name}.{key} has values that are not finite")
        if not nulls and not present.all():
            raise ProfileError(f"profile {name}: {section_name}.{key} must not contain null")
        return values

    def axis(section_name: str, key: str) -> np.ndarray:
        try:
            values = np.asarray(data[section_name][key], dtype=float)
        except (KeyError, TypeError, ValueError) as error:
            raise ProfileError(f"profile {name}: {section_name}.{key} is missing or not numeric") from error
        if values.ndim != 1 or values.size < 2:
            raise ProfileError(f"profile {name}: {section_name}.{key} needs at least two points")
        if not np.all(np.diff(values) > 0):
            raise ProfileError(f"profile {name}: {section_name}.{key} must be strictly increasing")
        return values

    sourced = status in SOURCED_STATUSES
    if sourced and not isinstance(data.get("source"), dict):
        raise ProfileError(f"profile {name}: status {status!r} requires a source section saying where the curves came from")

    sens_wl = axis("spectralSensitivity", "wavelengths")
    sensitivity = np.stack(
        [resample_log(sens_wl, table("spectralSensitivity", layer, sens_wl.size, nulls=True)) for layer in LAYERS],
        axis=1)
    if not np.all(sensitivity.max(axis=0) > 0):
        raise ProfileError(f"profile {name}: a layer has no spectral sensitivity on {WAVELENGTHS[0]:.0f} to {WAVELENGTHS[-1]:.0f} nm")

    curves_section = section("characteristicCurves")
    densitometry = curves_section.get("densitometry", "statusM")
    if densitometry not in ("statusM", "statusA"):
        raise ProfileError(f"profile {name}: characteristicCurves.densitometry must be statusM or statusA, not {densitometry!r}")
    log_exposure = axis("characteristicCurves", "logExposure")
    curves = np.stack(
        [table("characteristicCurves", layer, log_exposure.size) for layer in LAYERS], axis=1)
    if np.any(curves < 0):
        raise ProfileError(f"profile {name}: characteristic curves contain negative density")
    if np.any(np.diff(curves, axis=0) < -CURVE_FALL_TOLERANCE):
        raise ProfileError(f"profile {name}: characteristic curves must not fall as exposure rises")
    reference = curves_section.get("logExposureReference")
    if reference is not None:
        reference = _number(reference, f"{name}: characteristicCurves.logExposureReference")
    if measured and "logExposureReference" not in curves_section:
        raise ProfileError(f"profile {name}: status {status!r} requires characteristicCurves.logExposureReference")
    density_reference = curves_section.get("densityReference", "absolute")
    if density_reference not in ("absolute", "aboveToe"):
        raise ProfileError(f"profile {name}: characteristicCurves.densityReference must be absolute or aboveToe")
    speed_reference = curves_section.get("speedReference", True)
    if not isinstance(speed_reference, bool):
        raise ProfileError(f"profile {name}: characteristicCurves.speedReference must be a boolean")

    dye_section = section("dyeDensity")
    dye_wl = axis("dyeDensity", "wavelengths")
    if "cyan" in dye_section:
        dyes = np.stack([resample_hold(dye_wl, table("dyeDensity", dye, dye_wl.size)) for dye in DYES], axis=1)
        if np.any(dyes < 0):
            raise ProfileError(f"profile {name}: dye densities contain negative values")
        peaks = dyes.max(axis=0)
        if np.any(peaks <= 0):
            raise ProfileError(f"profile {name}: a dye has no density on the bake's wavelength range")
        dyes = dyes / peaks  # the amounts scale a peak-normalized dye
        if "minimumDensity" in dye_section:
            base = resample_hold(dye_wl, table("dyeDensity", "minimumDensity", dye_wl.size))
        else:
            base = np.zeros(WAVELENGTHS.size)
        unmixed = None
    elif "midscaleNeutral" in dye_section or "minimumDensity" in dye_section:
        midscale = table("dyeDensity", "midscaleNeutral", dye_wl.size)
        minimum = table("dyeDensity", "minimumDensity", dye_wl.size)
        if np.any(minimum < 0):
            raise ProfileError(f"profile {name}: dyeDensity.minimumDensity contains negative values")
        net = midscale - minimum
        if np.any(net <= 0):
            raise ProfileError(f"profile {name}: dyeDensity.midscaleNeutral must lie above minimumDensity everywhere")
        unmixed = unmix(dye_wl, net)
        dyes = unmixed.dyes
        base = resample_hold(dye_wl, minimum)
    else:
        raise ProfileError(f"profile {name}: dyeDensity needs either cyan, magenta and yellow or midscaleNeutral and minimumDensity")
    if np.any(base < 0):
        raise ProfileError(f"profile {name}: dyeDensity.minimumDensity contains negative values")

    plotted_to = float(log_exposure[-1])
    log_exposure, curves, top_slopes = extend_curves(log_exposure, curves)

    weights = status_weights("M" if densitometry == "statusM" else "A")
    density_offset = None
    if density_reference == "aboveToe":
        density_offset = status_density(base, weights) - curves.min(axis=0)
    targets = curves if density_offset is None else curves + density_offset
    amount_curves, residuals = invert_curves(targets, base, dyes, weights)
    if not np.all(np.isfinite(amount_curves)):
        raise ProfileError(f"profile {name}: the characteristic curves cannot be inverted into dye amounts")
    cross_talk = np.stack([status_density(dyes[:, k], weights) for k in range(3)], axis=1)
    if unmixed is not None:
        negative_model = unmixed.as_dict()
    else:
        negative_model = {
            "method": "explicit dye spectra from the profile",
            "rms": None,
            "maxError": None,
            "crossTalk": [[round(float(v), 6) for v in row] for row in cross_talk],
            "parameters": None,
        }
    if density_offset is not None:
        negative_model["toeDensityOffset"] = density_offset.round(6).tolist()

    try:
        couplers = np.asarray(data["couplers"]["interLayer"], dtype=float)
    except (KeyError, TypeError, ValueError) as error:
        raise ProfileError(f"profile {name}: couplers.interLayer is missing or not numeric") from error
    if couplers.shape != (3, 3) or not np.all(np.isfinite(couplers)):
        raise ProfileError(f"profile {name}: couplers.interLayer must be a 3 by 3 matrix")
    if np.any(couplers < 0):
        raise ProfileError(f"profile {name}: couplers.interLayer must not be negative")

    exposure = None
    if "exposureMatrix" in data:
        try:
            exposure = np.asarray(data["exposureMatrix"]["matrix"], dtype=float)
        except (KeyError, TypeError, ValueError) as error:
            raise ProfileError(f"profile {name}: exposureMatrix.matrix must be a 3 by 3 matrix") from error
        if exposure.shape != (3, 3) or not np.all(np.isfinite(exposure)):
            raise ProfileError(f"profile {name}: exposureMatrix.matrix must be a 3 by 3 matrix")
        if not np.allclose(exposure.sum(axis=1), 1.0, atol=1e-5):
            raise ProfileError(f"profile {name}: exposureMatrix rows must sum to one, or a gray would not stay neutral")
        if np.any(np.diag(exposure) <= 0):
            raise ProfileError(f"profile {name}: exposureMatrix must expose each layer by its own primary")

    modelled_film = data.get("modelledFilm")
    if modelled_film is not None and (not isinstance(modelled_film, str) or not modelled_film.strip()):
        raise ProfileError(f"profile {name}: modelledFilm must name the film the stock models")
    if sourced and modelled_film is None:
        raise ProfileError(f"profile {name}: status {status!r} requires modelledFilm, the film whose sheet it is built from")

    box_speed = _number(data.get("boxSpeed"), f"{name}: boxSpeed")
    if box_speed <= 0:
        raise ProfileError(f"profile {name}: boxSpeed must be a positive number")

    gray_card = white_step = forehead = None
    if data.get("grayCard") is not None:
        try:
            low, high = (_number(v, f"{name}: grayCard.redDensity") for v in data["grayCard"]["redDensity"])
        except (KeyError, TypeError, ValueError) as error:
            raise ProfileError(f"profile {name}: grayCard.redDensity must be [low, high]") from error
        if not low < high:
            raise ProfileError(f"profile {name}: grayCard.redDensity must be [low, high] with low below high")
        gray_card = (low, high)
        white_step = _window(data["grayCard"], "whiteStepRedDensity", name)
        forehead_section = data["grayCard"].get("foreheadRedDensity")
        if forehead_section is not None:
            if not isinstance(forehead_section, dict):
                raise ProfileError(f"profile {name}: grayCard.foreheadRedDensity must hold lightComplexion and darkComplexion")
            forehead = {key: _window(forehead_section, key, name) for key in ("lightComplexion", "darkComplexion")}
            if None in forehead.values():
                raise ProfileError(f"profile {name}: grayCard.foreheadRedDensity must hold lightComplexion and darkComplexion")
    elif measured and "grayCard" not in data:
        raise ProfileError(f"profile {name}: status {status!r} requires grayCard.redDensity, the sheet's window for a normally exposed gray card")

    grain_rms48 = None
    grain = data.get("grain")
    if isinstance(grain, dict) and grain.get("rmsGranularity48um") is not None:
        try:
            grain_rms48 = np.asarray(grain["rmsGranularity48um"], dtype=float)
        except (TypeError, ValueError) as error:
            raise ProfileError(f"profile {name}: grain.rmsGranularity48um must be three numbers") from error
        if grain_rms48.shape != (3,) or not np.all(np.isfinite(grain_rms48)) or np.any(grain_rms48 < 0):
            raise ProfileError(f"profile {name}: grain.rmsGranularity48um must be three non-negative numbers")

    halation = None
    raw_halation = data.get("halation")
    if isinstance(raw_halation, dict):
        try:
            halation = {key: _number(raw_halation[key], f"{name}: halation.{key}")
                        for key in ("strength", "greenShare", "radiusMicrometres")}
        except (KeyError, TypeError, ValueError) as error:
            raise ProfileError(f"profile {name}: halation needs numeric strength, greenShare and radiusMicrometres") from error
        # A strength of 0 is no halation, and then the radius does not matter.
        if (halation["strength"] < 0 or not 0 <= halation["greenShare"] <= 1 or halation["radiusMicrometres"] < 0
                or (halation["strength"] > 0 and halation["radiusMicrometres"] == 0)):
            raise ProfileError(f"profile {name}: halation needs strength >= 0, greenShare in [0, 1], and a "
                               "positive radiusMicrometres when the strength is positive")

    print_stage = data.get("printStage")
    if print_stage is not None and print_stage not in PRINT_STAGES:
        raise ProfileError(f"profile {name}: printStage must be one of {', '.join(PRINT_STAGES)} or null")

    capture_illuminant = data.get("captureIlluminantKelvin")
    if capture_illuminant is not None:
        capture_illuminant = _number(capture_illuminant, f"{name}: captureIlluminantKelvin")
        if not 1000 <= capture_illuminant <= 25000:
            raise ProfileError(f"profile {name}: captureIlluminantKelvin must be between 1000 and 25000")
    shoulder = data.get("highlightShoulder", "modeled")
    if shoulder not in ("modeled", "published"):
        raise ProfileError(f"profile {name}: highlightShoulder must be modeled or published")
    if shoulder == "published" and (not sourced or modelled_film is None):
        raise ProfileError(f"profile {name}: a published highlight shoulder requires a sourced film")

    variants = data.get("printVariants", [])
    if not isinstance(variants, list):
        raise ProfileError(f"profile {name}: printVariants must be a list")
    print_variants = []
    used_ids = {name}
    for variant in variants:
        if not isinstance(variant, dict):
            raise ProfileError(f"profile {name}: each print variant must be an object")
        variant_id, label, medium = (variant.get(key) for key in ("id", "displayName", "paper"))
        if (not isinstance(variant_id, str) or not STOCK_ID_PATTERN.fullmatch(variant_id)
                or variant_id in used_ids):
            raise ProfileError(f"profile {name}: print variant needs a unique stock id")
        if (not isinstance(label, str) or not label.strip() or not isinstance(medium, str)
                or not medium.strip() or medium == data.get("paper")):
            raise ProfileError(f"profile {name}: print variant needs a display name and a different print medium")
        used_ids.add(variant_id)
        print_variants.append(PrintVariant(variant_id, label, medium))

    return StockProfile(
        id=name,
        display_name=data.get("displayName", name),
        modelled_film=modelled_film,
        manufacturer=data.get("manufacturer", ""),
        status=status,
        box_speed=float(box_speed),
        paper=data.get("paper", ""),
        sensitivity=sensitivity,
        log_exposure=log_exposure,
        curves=curves,
        dyes=dyes,
        base=base,
        amount_curves=amount_curves,
        inversion_residual=float(np.max(np.abs(residuals))),
        couplers=couplers,
        gray_card=gray_card,
        white_step=white_step,
        forehead=forehead,
        halation=halation,
        log_exposure_reference=None if reference is None else float(reference),
        negative_model=negative_model,
        grain_rms48=grain_rms48,
        plotted_to=plotted_to,
        top_slopes=top_slopes,
        exposure_matrix=exposure,
        print_stage=print_stage,
        density_offset=density_offset,
        speed_reference=speed_reference,
        densitometry=densitometry,
        capture_illuminant_kelvin=capture_illuminant,
        has_published_shoulder=shoulder == "published",
        print_variants=tuple(print_variants),
    )


def top_slopes_of(log_exposure: np.ndarray, curves: np.ndarray, points: int = TOP_SLOPE_POINTS) -> np.ndarray:
    """Each curve's slope at the top of its plot: the least-squares line through its last `points` samples."""
    x = log_exposure[-points:]
    return np.array([np.polyfit(x, curves[-points:, k], 1)[0] for k in range(curves.shape[1])])


def extend_curves(log_exposure: np.ndarray, curves: np.ndarray, span: float = EXTENSION_LOG_H):
    """The curves with straight-line rows added past the last plotted point, at the plot's last spacing,
    for `span` log H; and the slopes they follow. A slope below zero is held at zero."""
    slopes = np.maximum(top_slopes_of(log_exposure, curves), 0.0)
    step = float(log_exposure[-1] - log_exposure[-2])
    count = int(math.ceil(span / step - 1e-9))
    added = log_exposure[-1] + step * np.arange(1, count + 1)
    rows = curves[-1] + (added - log_exposure[-1])[:, None] * slopes[None, :]
    return np.concatenate([log_exposure, added]), np.vstack([curves, rows]), slopes
