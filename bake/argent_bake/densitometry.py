"""Status A and Status M densitometry (ISO 5-3:1995), and the inversion of status densities
into dye amounts.

A datasheet's characteristic curves are status densities of the whole negative or print:
each channel integrates the transmitted light against a spectral product, so a dye's
density reads into every channel, not only its own. `status_density` reproduces the
densitometer; `dye_amounts_for` runs it backwards, solving for the non-negative amounts
of three unit-peak dyes over a base spectrum that read as a given triple.

The spectral products come from `data/iso5-3_status_a_m_log_spectral_products.csv`:
log10 values at 10 nm, extended beyond the table with the standard's end slopes,
interpolated in the log domain onto the bake grid, and normalized so that a flat density
D reads exactly D.
"""

from functools import lru_cache

import numpy as np

from .spectral import WAVELENGTHS, load_data_text

STATUS_TABLE = "iso5-3_status_a_m_log_spectral_products.csv"
CHANNELS = ("red", "green", "blue")


class InversionError(RuntimeError):
    """The dye amounts could not be solved for: the dyes cannot tell the channels apart."""


@lru_cache(maxsize=None)
def _status_table() -> dict:
    """{column name: (wavelengths, log10 values, slope below, slope above)} from the ISO file."""
    header = None
    rows = []
    slopes = {}
    for line in load_data_text(STATUS_TABLE).splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            body = line[1:].strip()
            # "A_blue: +0.380/nm below 420 nm ; -0.140/nm above 500 nm"
            if ":" in body and "/nm" in body and ";" in body:
                name, rest = body.split(":", 1)
                below, above = rest.split(";")
                slopes[name.strip()] = (float(below.split("/nm")[0]), float(above.split("/nm")[0]))
            continue
        parts = line.split(",")
        if header is None:
            header = [p.strip() for p in parts]
            continue
        rows.append([float(v) if v.strip() else float("nan") for v in parts])
    table = np.asarray(rows, dtype=float)
    out = {}
    for column, name in enumerate(header[1:], start=1):
        valid = np.isfinite(table[:, column])
        out[name] = (table[valid, 0], table[valid, column], *slopes[name])
    return out


def status_weights(kind: str, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """Spectral products of Status A or Status M on `wl`, as an (n, 3) array in red, green, blue order.

    Each column sums to one, so the status density of a flat spectrum equals its density.
    """
    kind = kind.upper()
    if kind not in ("A", "M"):
        raise ValueError(f"status densitometry is A or M, not {kind!r}")
    table = _status_table()
    columns = []
    for channel in CHANNELS:
        table_wl, log_values, slope_below, slope_above = table[f"{kind}_{channel}"]
        log_w = np.interp(wl, table_wl, log_values)
        below = wl < table_wl[0]
        above = wl > table_wl[-1]
        log_w[below] = log_values[0] + slope_below * (wl[below] - table_wl[0])
        log_w[above] = log_values[-1] + slope_above * (wl[above] - table_wl[-1])
        w = 10.0 ** log_w
        columns.append(w / w.sum())
    return np.stack(columns, axis=1)


def status_density(spectral_density: np.ndarray, weights: np.ndarray) -> np.ndarray:
    """Status density per channel for spectral densities of shape (..., n), with weights (n, 3)."""
    transmission = 10.0 ** -np.asarray(spectral_density, dtype=float)
    return -np.log10(transmission @ weights)


def status_jacobian(spectral_density: np.ndarray, weights: np.ndarray, dyes: np.ndarray) -> np.ndarray:
    """d(status density of channel c) / d(amount of dye k) at one spectral density (n,).

    J[c, k] = sum(w_c T K_k) / sum(w_c T) with T the transmission: the transmission-weighted
    mean of dye k under channel c.
    """
    transmission = 10.0 ** -np.asarray(spectral_density, dtype=float)
    weighted = weights * transmission[:, None]
    return (weighted.T @ dyes) / weighted.sum(axis=0)[:, None]


def dye_amounts_for(target: np.ndarray, base: np.ndarray, dyes: np.ndarray, weights: np.ndarray,
                    start: np.ndarray | None = None, tolerance: float = 1e-10, iterations: int = 60):
    """Non-negative amounts a with status_density(base + dyes @ a) equal to `target`.

    Projected Newton with the analytic Jacobian: a component whose step would take it
    negative is pinned, its step taking it to zero, and dropped from the solve, and a
    halving line search on the residual norm judges the whole move, so the amounts
    returned are never worse than the last ones accepted. Returns (amounts, residual,
    iterations). Where the target lies below what the base alone reads, the amounts pin at
    zero and the residual stays; the caller decides whether that is acceptable.
    """
    amounts = np.zeros(3) if start is None else np.maximum(np.asarray(start, dtype=float), 0.0)
    target = np.asarray(target, dtype=float)
    for iteration in range(iterations):
        density = base + dyes @ amounts
        residual = status_density(density, weights) - target
        if np.max(np.abs(residual)) < tolerance:
            return amounts, residual, iteration
        jacobian = status_jacobian(density, weights, dyes)
        free = np.ones(3, dtype=bool)
        step = np.zeros(3)
        for _ in range(3):
            columns = np.flatnonzero(free)
            if columns.size == 0:
                break
            step[:] = 0.0
            try:
                step[columns] = np.linalg.solve(jacobian[np.ix_(columns, columns)], -residual[columns])
            except np.linalg.LinAlgError as failure:
                raise InversionError("the dye set cannot separate the status channels") from failure
            blocked = free & (amounts + step < 0.0)
            if not blocked.any():
                break
            worst = int(np.argmin(np.where(blocked, amounts + step, np.inf)))
            free[worst] = False
        step[~free] = -amounts[~free]
        if not step.any():
            break
        norm = np.linalg.norm(residual)
        scale = 1.0
        for _ in range(20):
            trial = np.maximum(amounts + scale * step, 0.0)
            trial_residual = status_density(base + dyes @ trial, weights) - target
            if np.linalg.norm(trial_residual) < norm:
                break
            scale /= 2.0
        else:
            break
        amounts = trial
    density = base + dyes @ amounts
    return amounts, status_density(density, weights) - target, iterations


def invert_curves(targets: np.ndarray, base: np.ndarray, dyes: np.ndarray, weights: np.ndarray):
    """Dye amounts (m, 3) whose status densities equal the rows of `targets` (m, 3), and the residuals (m, 3).

    Each row is warm-started from the previous one, so a monotonic curve inverts in a
    couple of Newton steps per sample.
    """
    targets = np.asarray(targets, dtype=float)
    amounts = np.zeros_like(targets)
    residuals = np.zeros_like(targets)
    start = None
    for i, target in enumerate(targets):
        amounts[i], residuals[i], _ = dye_amounts_for(target, base, dyes, weights, start)
        start = amounts[i]
    return amounts, residuals
