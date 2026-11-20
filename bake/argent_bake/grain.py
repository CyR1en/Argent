"""Grain through the print: how density noise on the negative shows on the paper.

M3 injects grain into the negative's dye amounts before the Print LUT (docs/M3-research.md,
section 3). This module measures what that does through the real print model, so the grain
numbers rest on the Endura Premier paper rather than the synthetic one the research first
used.

Grain is modelled as independent noise in each layer's dye. A sheet's RMS granularity is a
density fluctuation read through a status filter (Status M assumed, inference), and a dye
reads into every channel, so the per-layer amount variances are solved from the per-channel
density variances through the squared Status M Jacobian. The print model's own Jacobian then
carries them to display-linear Rec. 2020, giving the output covariance, its channel
correlations and the relative luminance noise.

The full chain for a stock follows the research's formulas: sigma48 per layer from the
profile, times r(p) for the output's pixel pitch (F4), times the density response s(net D)
(F7), where net D is the sheet's curve at that exposure minus its minimum.
"""

from dataclasses import dataclass

import numpy as np

from .densitometry import status_jacobian, status_weights
from .negative import MID_GRAY, dye_amounts, mid_gray_log_exposure
from .printing import Printer
from .profile import StockProfile

REC2020_LUMINANCE = np.array([0.2627, 0.6780, 0.0593])

# F4: per-pixel sigma over sigma48 for the 6.5 and 15 micrometre cloud mixture, by output
# long side in pixels of a 36 mm frame (pitches 5.137, 10.27, 17.58, 20.55 and 41.1
# micrometres). The research agent's calculation, docs/M3-research.md.
PIXEL_RATIO = {7008: 4.02, 3504: 2.95, 2048: 2.07, 1752: 1.84, 876: 1.02}

# F7: density response s(net D) per layer, read from the VISION3 500T granularity curves and
# used for every stock (reported, then read by eye; the 2.0 red value is extrapolated).
RESPONSE_NET_DENSITY = np.array([0.0, 0.2, 0.4, 0.7, 1.0, 1.5, 2.0])
RESPONSE = np.array([
    [0.85, 1.65, 1.20, 0.98, 1.00, 0.90, 0.75],  # red
    [1.06, 1.90, 1.47, 1.25, 1.00, 1.16, 0.94],  # green
    [1.45, 1.63, 1.47, 1.06, 1.00, 1.03, 0.60],  # blue
])


@dataclass(frozen=True)
class PrintNoise:
    stops: float  # scene exposure relative to a metered mid-gray
    output: np.ndarray  # (3,) display-linear Rec. 2020 of the print
    luminance: float
    relative_luminance_sigma: float  # sigma_Y / Y
    correlation: np.ndarray  # (3, 3) between the output channels
    sigma_amounts: np.ndarray  # (3,) per-layer dye amount sigma, unnormalized
    sigma_density: np.ndarray  # (3,) the Status M density sigma it was solved from


def jacobian(f, x: np.ndarray, step: float = 1e-4) -> np.ndarray:
    """d f / d x by central differences, columns per input."""
    return np.stack([(f(x + step * e) - f(x - step * e)) / (2.0 * step) for e in np.eye(x.size)], axis=1)


def amount_variances(profile: StockProfile, amounts: np.ndarray, sigma_density) -> np.ndarray:
    """Per-layer dye amount variances whose Status M density variances are `sigma_density` squared.

    A dye's fluctuation reads into every channel through the Status M Jacobian J, so the
    channel variances are (J * J) @ var. Solved and floored at zero.
    """
    j = status_jacobian(profile.base + profile.dyes @ amounts, status_weights("M"), profile.dyes)
    return np.maximum(np.linalg.solve(j * j, np.asarray(sigma_density, dtype=float) ** 2), 0.0)


def print_noise(profile: StockProfile, printer: Printer, filtration: np.ndarray, stops: float,
                sigma_density) -> PrintNoise:
    """The print's noise for a neutral scene `stops` from mid-gray with per-channel density sigma `sigma_density`."""
    amounts = dye_amounts(profile, np.full(3, MID_GRAY * 2.0 ** stops))
    variances = amount_variances(profile, amounts, sigma_density)
    output = printer(amounts, filtration)
    gain = jacobian(lambda a: printer(a, filtration), amounts)
    covariance = gain @ np.diag(variances) @ gain.T
    luminance = float(REC2020_LUMINANCE @ output)
    sigma = np.sqrt(np.maximum(np.diag(covariance), 1e-30))
    return PrintNoise(
        stops=float(stops),
        output=output,
        luminance=luminance,
        relative_luminance_sigma=float(np.sqrt(REC2020_LUMINANCE @ covariance @ REC2020_LUMINANCE)) / luminance,
        correlation=covariance / np.outer(sigma, sigma),
        sigma_amounts=np.sqrt(variances),
        sigma_density=np.asarray(sigma_density, dtype=float),
    )


def net_density(profile: StockProfile, stops: float) -> np.ndarray:
    """The sheet's Status M density above each layer's minimum for a neutral scene `stops` from mid-gray."""
    log_h = mid_gray_log_exposure(profile.box_speed) + stops * np.log10(2.0)
    density = np.array([np.interp(log_h, profile.log_exposure, profile.curves[:, k]) for k in range(3)])
    return density - profile.curves.min(axis=0)


def density_response(net: np.ndarray) -> np.ndarray:
    """s(net D) per layer, F7, held flat beyond the table."""
    return np.array([np.interp(net[k], RESPONSE_NET_DENSITY, RESPONSE[k]) for k in range(3)])


def stock_sigma_density(profile: StockProfile, sigma48, stops: float, long_side: int) -> np.ndarray:
    """Per-pixel Status M density sigma per layer at an output of `long_side` pixels: sigma48 * r(p) * s(net D)."""
    if long_side not in PIXEL_RATIO:
        raise ValueError(f"no pixel ratio for {long_side} px; known: {sorted(PIXEL_RATIO)}")
    return np.asarray(sigma48, dtype=float) * PIXEL_RATIO[long_side] * density_response(net_density(profile, stops))


# The manifest's grain table: a neutral sweep, in quarter stops, from eight under mid-gray to five
# over, the Negative LUT's range.
TABLE_STOPS = np.arange(-8.0, 5.0 + 1e-9, 0.25)


def grain_table(profile: StockProfile, density_range: float, stops: np.ndarray = TABLE_STOPS) -> dict:
    """The runtime's grain inputs: per layer, the Negative LUT's normalized dye amount at each
    exposure of a neutral sweep and the per-layer dye amount sigma there at a 48 micrometre
    aperture, also normalized, so the app looks a pixel's grain up by its own dye amount.

    sigma48 per layer from the profile times the density response s(net D) (F7) gives the
    Status M density sigma, solved into dye amounts through the Status M Jacobian. The output
    pixel's pitch, r(p) (F4), is applied at runtime.
    """
    if profile.grain_rms48 is None:
        return {}
    amounts, sigmas = [], []
    for value in stops:
        own = dye_amounts(profile, np.full(3, MID_GRAY * 2.0 ** value))
        sigma_density = profile.grain_rms48 * density_response(net_density(profile, value))
        amounts.append(own / density_range)
        sigmas.append(np.sqrt(amount_variances(profile, own, sigma_density)) / density_range)
    amounts = np.maximum.accumulate(np.array(amounts), axis=0)  # held monotonic for lookup
    return {
        "stops": [round(float(v), 4) for v in stops],
        "amounts": [[round(float(x), 6) for x in row] for row in amounts],
        "sigma48": [[round(float(x), 7) for x in row] for row in np.array(sigmas)],
        "basis": "per-layer dye amount sigma at a 48 um aperture over a neutral sweep, both divided by "
                 "densityRange: rmsGranularity48um times the VISION3 density response, through the Status M "
                 "Jacobian (argent_bake.grain); the app applies the output pitch's r(p)",
    }
