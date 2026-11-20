"""Unmix a datasheet's midscale neutral spectrum into three dyes.

A colour negative sheet publishes two spectral density curves, Midscale Neutral and
Minimum Density, and never the dyes themselves. Their difference is the density the three
dyes add at a neutral exposure. This module fits it with three unimodal lobes, one per dye:
an asymmetric power-exponential exp(-0.5 |(l - mu) / s|^p) with its own width s on each
side of the peak and one exponent p per lobe, bounded to [1.5, 2.5] (2 is a Gaussian, 1.5
has heavier tails). There are no secondary lobes: the effective dyes of a masked colour
negative have small unwanted absorptions by design, because the mask cancels them. The
cyan lobe is symmetric: the sheets stop at 700 nm, a few nanometres past the cyan peak, so
its long-wavelength side is unseen and a free width there ran to a bound.

The fit cannot see how much of the density near 500 nm belongs to magenta rather than
yellow, or near 600 nm to cyan rather than magenta; several dye sets reproduce the sheet
within a few thousandths of a density. The cross-talk the fit lands on is therefore a
modelling prior, reported in the result so the scan fit of M4 can tune it, not a measured
property of the film.

Parameters are bounded through a sigmoid map and fitted by Levenberg-Marquardt with a
central-difference Jacobian from 24 starts drawn with a fixed seed; the best is kept, so
the result is deterministic. numpy only.
"""

from dataclasses import dataclass

import numpy as np

from .densitometry import status_density, status_weights
from .spectral import WAVELENGTHS

DYES = ("cyan", "magenta", "yellow")
PEAK_BOUNDS = ((630.0, 725.0), (530.0, 560.0), (430.0, 460.0))  # nm, per dye
WIDTH_BOUNDS = (12.0, 120.0)  # nm, each side
EXPONENT_BOUNDS = (1.5, 2.5)
AMOUNT_BOUNDS = (0.3, 2.0)
STARTS = 24
SEED = 7
START_SPREAD = 0.6  # standard deviation of the random starts in the unbounded coordinates
# The fitted vector: cyan (peak, width, exponent, amount), then magenta and yellow
# (peak, width below, width above, exponent, amount). The cyan width serves both sides.
FIRST_GUESS = (690.0, 60.0, 2.0, 1.0,
               545.0, 35.0, 30.0, 2.0, 1.0,
               448.0, 40.0, 35.0, 2.0, 1.0)
LAYOUT = (0, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13)  # fitted index of each (dye, lobe parameter)
PARAMETERS_PER_DYE = 5  # peak, width below, width above, exponent, amount, after expansion
METHOD = ("three power-exponential lobes, one exponent per lobe in [1.5, 2.5], widths 12 to 120 nm "
          "on each side (the cyan lobe symmetric), no secondary lobes; Levenberg-Marquardt from 24 seeded starts")


@dataclass(frozen=True)
class Unmixing:
    dyes: np.ndarray  # (n, 3) unit-peak spectral density of cyan, magenta, yellow on WAVELENGTHS
    amounts: np.ndarray  # (3,) amounts at the midscale neutral
    parameters: dict  # per dye: peak, widthBelow, widthAbove, exponent
    rms: float  # density, over the sheet's wavelengths
    max_error: float  # density
    max_error_wavelength: float  # nm
    cross_talk: np.ndarray  # (3, 3) Status M density per unit of each dye; rows R, G, B; columns C, M, Y

    def as_dict(self) -> dict:
        """The provenance the manifest carries."""
        return {
            "method": METHOD,
            "rms": round(self.rms, 6),
            "maxError": round(self.max_error, 6),
            "maxErrorWavelength": self.max_error_wavelength,
            "midscaleAmounts": [round(float(v), 6) for v in self.amounts],
            "crossTalk": [[round(float(v), 6) for v in row] for row in self.cross_talk],
            "parameters": self.parameters,
        }


def lobe(wl: np.ndarray, peak: float, width_below: float, width_above: float, exponent: float) -> np.ndarray:
    """One unit-peak dye lobe."""
    x = np.asarray(wl, dtype=float) - peak
    width = np.where(x < 0.0, width_below, width_above)
    return np.exp(-0.5 * np.abs(x / width) ** exponent)


def _bounds() -> tuple[np.ndarray, np.ndarray]:
    """Lower and upper bounds of the fitted vector."""
    low = [PEAK_BOUNDS[0][0], WIDTH_BOUNDS[0], EXPONENT_BOUNDS[0], AMOUNT_BOUNDS[0]]
    high = [PEAK_BOUNDS[0][1], WIDTH_BOUNDS[1], EXPONENT_BOUNDS[1], AMOUNT_BOUNDS[1]]
    for k in (1, 2):
        low += [PEAK_BOUNDS[k][0], WIDTH_BOUNDS[0], WIDTH_BOUNDS[0], EXPONENT_BOUNDS[0], AMOUNT_BOUNDS[0]]
        high += [PEAK_BOUNDS[k][1], WIDTH_BOUNDS[1], WIDTH_BOUNDS[1], EXPONENT_BOUNDS[1], AMOUNT_BOUNDS[1]]
    return np.asarray(low), np.asarray(high)


def _expand(fitted: np.ndarray) -> np.ndarray:
    """The fitted vector (..., 14) as lobe parameters (..., 3, 5)."""
    return fitted[..., list(LAYOUT)].reshape(fitted.shape[:-1] + (3, PARAMETERS_PER_DYE))


def _sigmoid(q: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(q, -40.0, 40.0)))


def _to_parameters(q: np.ndarray, low: np.ndarray, high: np.ndarray) -> np.ndarray:
    return low + (high - low) * _sigmoid(q)


def _to_unbounded(p: np.ndarray, low: np.ndarray, high: np.ndarray) -> np.ndarray:
    fraction = np.clip((p - low) / (high - low), 1e-9, 1.0 - 1e-9)
    return np.log(fraction / (1.0 - fraction))


def _model(fitted: np.ndarray, wl: np.ndarray) -> np.ndarray:
    """Summed dye density for fitted vectors of shape (..., 14), as (..., n)."""
    p = _expand(fitted)
    peak, below, above, exponent, amount = (p[..., i][..., None] for i in range(PARAMETERS_PER_DYE))
    x = wl - peak
    width = np.where(x < 0.0, below, above)
    lobes = np.exp(-0.5 * np.abs(x / width) ** exponent)
    return (amount * lobes).sum(axis=-2)


def _levenberg_marquardt(residual, q0: np.ndarray, iterations: int = 300, tolerance: float = 1e-14):
    """Minimize |residual(q)|^2. `residual` must accept a batch of parameter vectors."""
    q = q0.copy()
    r = residual(q[None, :])[0]
    cost = r @ r
    damping = 1e-3
    step = 1e-6
    for _ in range(iterations):
        offsets = step * np.eye(q.size)
        probes = np.concatenate([q[None, :] + offsets, q[None, :] - offsets], axis=0)
        values = residual(probes)
        jacobian = ((values[:q.size] - values[q.size:]) / (2.0 * step)).T
        gradient = jacobian.T @ r
        hessian = jacobian.T @ jacobian
        improved = False
        delta = np.zeros_like(q)
        for _ in range(30):
            try:
                delta = np.linalg.solve(hessian + damping * np.diag(np.diag(hessian) + 1e-12), -gradient)
            except np.linalg.LinAlgError:
                damping *= 10.0
                continue
            r_new = residual((q + delta)[None, :])[0]
            cost_new = r_new @ r_new
            if cost_new < cost:
                q, r, cost = q + delta, r_new, cost_new
                damping = max(damping / 3.0, 1e-12)
                improved = True
                break
            damping *= 4.0
        if not improved or delta @ delta < tolerance:
            break
    return q, cost


def unmix(wavelengths: np.ndarray, net_density: np.ndarray, wl: np.ndarray = WAVELENGTHS) -> Unmixing:
    """Fit three dye lobes to `net_density` (midscale neutral minus minimum density) on `wavelengths`.

    The dyes come back peak-normalized on `wl`, with the peak folded into the amount.
    """
    wavelengths = np.asarray(wavelengths, dtype=float)
    net_density = np.asarray(net_density, dtype=float)
    low, high = _bounds()

    def residual(q: np.ndarray) -> np.ndarray:
        return _model(_to_parameters(q, low, high), wavelengths) - net_density

    rng = np.random.default_rng(SEED)
    q0 = _to_unbounded(np.asarray(FIRST_GUESS, dtype=float).ravel(), low, high)
    best = None
    for start in range(STARTS):
        q_start = q0 if start == 0 else q0 + rng.normal(0.0, START_SPREAD, q0.size)
        q, cost = _levenberg_marquardt(residual, q_start)
        if best is None or cost < best[1]:
            best = (q, cost)
    fitted = _to_parameters(best[0], low, high)
    p = _expand(fitted)

    dyes = np.stack([lobe(wl, *p[k, :4]) for k in range(3)], axis=1)
    peaks = dyes.max(axis=0)
    dyes = dyes / peaks
    amounts = p[:, 4] * peaks

    error = _model(fitted, wavelengths) - net_density
    cross_talk = np.stack([status_density(dyes[:, k], status_weights("M", wl)) for k in range(3)], axis=1)
    parameters = {
        name: {"peak": round(float(p[k, 0]), 3), "widthBelow": round(float(p[k, 1]), 3),
               "widthAbove": round(float(p[k, 2]), 3), "exponent": round(float(p[k, 3]), 4)}
        for k, name in enumerate(DYES)
    }
    return Unmixing(
        dyes=dyes,
        amounts=amounts,
        parameters=parameters,
        rms=float(np.sqrt(np.mean(error ** 2))),
        max_error=float(np.max(np.abs(error))),
        max_error_wavelength=float(wavelengths[np.argmax(np.abs(error))]),
        cross_talk=cross_talk,
    )
