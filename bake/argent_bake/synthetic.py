"""A synthetic stock and paper: invented numbers with the right shapes.

They exist so the bake and the render graph can run end to end on something that is not
a real film. Nothing here is measured. The curves are logistic, the spectra are Gaussians,
and the result is a plausible-looking negative-positive process, not a look and not any
real film. Output baked from it is labeled `synthetic` all the way to the app.

The profile takes the explicit-dye form of schema 2 (cyan, magenta and yellow spectra with
no minimum density spectrum), so its characteristic curves are inverted into dye amounts
over a clear base by the same code path a datasheet profile takes, and it carries a
gray-card window around its own mid-gray red density so the gates run on it too.
"""

import numpy as np

from .negative import mid_gray_log_exposure
from .printing import PaperModel
from .profile import load_profile
from .spectral import blackbody, daylight, gaussian

PROFILE_ID = "synthetic-v0"
PAPER_NAME = "synthetic-print-v0"
BOX_SPEED = 400.0

# Film layers: base density (the orange mask included), the slope of the straight part in
# density per log10 exposure, and a small shift so the gray axis is not perfectly gray.
NET_DENSITY = 2.0
LAYER_BASE = (0.30, 0.65, 1.05)
LAYER_SLOPE = (0.60, 0.61, 0.59)
LAYER_SHIFT = (0.01, 0.0, -0.01)
# Density above base at mid-gray, and how soft the toe and shoulder knees are.
MID_GRAY_NET = 0.8
FILM_KNEE = 3.0
PAPER_KNEE = 6.0
# Half-width of the gray-card window the profile carries, in density, around its own mid-gray.
GRAY_CARD_HALF_WIDTH = 0.05


def _ramp(x: np.ndarray, base: float, slope: float, start: float, stop: float, knee: float) -> np.ndarray:
    """Density that rises at `slope` from `start` and levels off at `stop`, with soft knees.

    A straight middle with a toe and a shoulder, which is how a negative or a paper is
    drawn on a datasheet. `knee` is the sharpness; larger is harder.
    """
    def softplus(u):
        return np.logaddexp(0.0, knee * u) / knee

    return base + slope * (softplus(x - start) - softplus(x - stop))


def _round(values: np.ndarray) -> list:
    return [round(float(v), 6) for v in values]


def _peak_normalized(spectrum: np.ndarray) -> np.ndarray:
    return spectrum / spectrum.max()


def profile_dict() -> dict:
    """The synthetic stock as the JSON a datasheet digitization would produce."""
    wl = np.arange(380.0, 781.0, 10.0)
    log_x = np.round(np.arange(-4.5, 1.0001, 0.05), 6)
    mid = mid_gray_log_exposure(BOX_SPEED)

    def log_sensitivity(center: float, width: float) -> np.ndarray:
        return np.log10(np.maximum(gaussian(center, width, wl), 1e-3))

    curves = []
    for base, slope, shift in zip(LAYER_BASE, LAYER_SLOPE, LAYER_SHIFT):
        start = mid - MID_GRAY_NET / slope + shift  # mid-gray sits MID_GRAY_NET up the straight part
        curves.append(_ramp(log_x, base, slope, start, start + NET_DENSITY / slope, FILM_KNEE))
    red_at_mid = float(np.interp(mid, log_x, curves[0]))

    return {
        "schema": 2,
        "id": PROFILE_ID,
        "displayName": "Synthetic",
        "manufacturer": "Argent",
        "boxSpeed": BOX_SPEED,
        "status": "synthetic",
        "notes": "Invented numbers that exercise the bake. Not measured, not a look.",
        "spectralSensitivity": {
            "wavelengths": _round(wl),
            "red": _round(log_sensitivity(640.0, 35.0)),
            "green": _round(log_sensitivity(545.0, 32.0)),
            "blue": _round(log_sensitivity(450.0, 28.0)),
        },
        "characteristicCurves": {
            "densitometry": "statusM",
            "logExposure": _round(log_x),
            "red": _round(curves[0]),
            "green": _round(curves[1]),
            "blue": _round(curves[2]),
            "logExposureReference": round(mid, 6),
        },
        "dyeDensity": {
            "wavelengths": _round(wl),
            "cyan": _round(gaussian(655.0, 52.0, wl) + 0.12 * gaussian(430.0, 40.0, wl)),
            "magenta": _round(gaussian(548.0, 40.0, wl) + 0.22 * gaussian(435.0, 45.0, wl)
                              + 0.04 * gaussian(650.0, 40.0, wl)),
            "yellow": _round(gaussian(442.0, 38.0, wl) + 0.05 * gaussian(550.0, 45.0, wl)),
        },
        "grayCard": {
            "redDensity": [round(red_at_mid - GRAY_CARD_HALF_WIDTH, 3), round(red_at_mid + GRAY_CARD_HALF_WIDTH, 3)],
            "source": "the synthetic red curve at its own mid-gray, plus or minus 0.05; not a sheet value",
        },
        "couplers": {
            "interLayer": [[0.00, 0.10, 0.04],
                           [0.12, 0.00, 0.10],
                           [0.04, 0.10, 0.00]],
        },
        "halation": {"strength": 0, "greenShare": 0, "radiusMicrometres": 0},
        "grain": {"printGrainIndex": [None, None, None], "relativeSigma": 0, "rmsGranularity48um": [0, 0, 0]},
        "paper": PAPER_NAME,
        "correctionLUT": None,
    }


def profile():
    """The synthetic stock, loaded the same way a profile file would be."""
    return load_profile(profile_dict())


def paper() -> PaperModel:
    """The synthetic print paper, enlarger lamp, and viewing light."""
    x = np.arange(-5.0, 2.0001, 0.05)

    def curve(slope: float) -> np.ndarray:
        return _ramp(x, 0.05, slope, -2.0, -2.0 + 2.3 / slope, PAPER_KNEE)

    return PaperModel(
        name=PAPER_NAME,
        sensitivity=np.stack([gaussian(650.0, 33.0), gaussian(545.0, 30.0), gaussian(445.0, 27.0)], axis=1),
        log_exposure=x,
        curves=np.stack([curve(2.1), curve(2.15), curve(2.05)], axis=1),
        dyes=np.stack([
            _peak_normalized(gaussian(645.0, 48.0) + 0.10 * gaussian(430.0, 40.0) + 0.05 * gaussian(540.0, 40.0)),
            _peak_normalized(gaussian(545.0, 38.0) + 0.16 * gaussian(430.0, 40.0) + 0.04 * gaussian(650.0, 40.0)),
            _peak_normalized(gaussian(440.0, 35.0) + 0.03 * gaussian(540.0, 40.0)),
        ], axis=1),
        enlarger=blackbody(3200.0),  # tungsten-halogen
        viewing=daylight(5003.0),  # CIE D50
        display_name="Synthetic print",
        status="synthetic",
    )
