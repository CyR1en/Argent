"""The print: negative dye amounts to display-linear light, baked into the Print LUT.

The shared print model, in the order light meets it:

1. The enlarger lamp shines through the negative, whose spectral density is its base and
   mask spectrum plus its three dye amounts times the dye spectra.
2. Each paper layer integrates that light against its sensitivity. Exposure is measured
   against a clear negative, and a per-layer offset in log exposure stands for enlarger
   filtration and time.
3. The print curves turn log exposure into dye amounts. The dyes attenuate the light
   reflected from paper or transmitted through print film.
4. The viewing light turns the result into XYZ. Bradford adaptation takes the viewing
   white to D65; clear print film or paper white maps to (1, 1, 1) in linear Rec. 2020.

Lab balance in the render graph is an offset on the negative's dye amounts, which moves
paper exposure the same way filtration does. The offsets solved here are the daylight
reference: the filtration at which a mid-gray exposure prints as a neutral gray.
`exposure_per_unit` measures how much paper exposure a unit of each dye moves, so the
app can turn stops of lab balance into amount offsets.
"""

from dataclasses import dataclass

import numpy as np

from .densitometry import dye_amounts_for, status_weights
from .spectral import (D65_XY, WAVELENGTHS, adaptation_matrix, cie_1931, rgb_to_xyz_matrix, white_point, xy_to_xyz)

# Display-linear value a neutral mid-gray exposure prints to at the daylight reference.
GRAY_TARGET = 0.18

CHUNK = 16384


class CalibrationError(RuntimeError):
    """The daylight reference could not be solved for."""


@dataclass(frozen=True)
class PaperModel:
    name: str
    sensitivity: np.ndarray  # (n, 3) linear spectral sensitivity of the red, green, and blue layers
    log_exposure: np.ndarray  # (m,) log10 exposure relative to a clear negative
    curves: np.ndarray  # (m, 3) amount of each paper dye against log exposure, paper white excluded
    dyes: np.ndarray  # (n, 3) cyan, magenta, and yellow spectral density, peak 1.0
    enlarger: np.ndarray  # (n,) lamp spectrum
    viewing: np.ndarray  # (n,) light the print is viewed under
    base: np.ndarray | None = None  # (n,) spectral density of the unexposed paper, for an absolute render
    status_curves: np.ndarray | None = None  # (m, 3) the sheet's status densities the curves were inverted from
    densitometry: str = ""  # statusA or statusM, for status_curves
    inversion_residual: float = 0.0  # largest status density residual of that inversion
    display_name: str = ""
    status: str = ""
    medium: str = "reflection"
    lab_aim_density: np.ndarray | None = None  # Status A densities of the print LAD patch


@dataclass(frozen=True)
class ToneStage:
    """A lab's tone stage between the negative and the paper: per paper layer, a monotone map of log10 paper
    exposure (filtration included) to the log10 exposure the paper receives, as a digital printer's
    calibration does (docs/research/film-sim/print.md section 4). Linear interpolation between the knots,
    the end slopes held beyond them."""

    knots_in: np.ndarray  # (n, 3)
    knots_out: np.ndarray  # (n, 3)
    name: str = ""

    def inverse(self, y: np.ndarray) -> np.ndarray:
        """The input that maps to `y` (3,), inside the knots."""
        return np.array([np.interp(y[k], self.knots_out[:, k], self.knots_in[:, k]) for k in range(3)])

    def __call__(self, x: np.ndarray) -> np.ndarray:
        out = np.empty_like(x)
        for k in range(3):
            xi, yi = self.knots_in[:, k], self.knots_out[:, k]
            v = np.interp(x[..., k], xi, yi)
            lo = (yi[1] - yi[0]) / (xi[1] - xi[0])
            hi = (yi[-1] - yi[-2]) / (xi[-1] - xi[-2])
            v = np.where(x[..., k] < xi[0], yi[0] + lo * (x[..., k] - xi[0]), v)
            out[..., k] = np.where(x[..., k] > xi[-1], yi[-1] + hi * (x[..., k] - xi[-1]), v)
        return out


class Printer:
    """The print model for one negative: its dye spectra and base fix how its amounts become light."""

    def __init__(self, paper: PaperModel, negative_dyes: np.ndarray, negative_base: np.ndarray | None = None,
                 stage: ToneStage | None = None):
        self.paper = paper
        self.stage = stage
        self._negative_dyes = negative_dyes
        self._negative_base = np.zeros(WAVELENGTHS.size) if negative_base is None else negative_base
        self._lamp = paper.sensitivity * paper.enlarger[:, None]
        self._clear = self._lamp.sum(axis=0)

        cmf = cie_1931()
        viewing = paper.viewing
        if paper.medium == "transmission":
            viewing = viewing * 10.0 ** -paper.base
        self._observer = cmf * viewing[:, None] / (cmf[:, 1] @ viewing)
        adapt = adaptation_matrix(white_point(viewing), xy_to_xyz(*D65_XY))
        self._to_rgb = np.linalg.inv(rgb_to_xyz_matrix()) @ adapt

    def log_exposure(self, amounts: np.ndarray) -> np.ndarray:
        """log10 paper exposure per layer, relative to a clear negative, for dye amounts (..., 3)."""
        transmission = 10.0 ** -(self._negative_base + amounts @ self._negative_dyes.T)
        return np.log10(np.maximum(transmission @ self._lamp / self._clear, 1e-12))

    def __call__(self, amounts: np.ndarray, offsets: np.ndarray) -> np.ndarray:
        """Display-linear Rec. 2020 for negative dye amounts (..., 3) and filtration `offsets` (3,)."""
        x = self.log_exposure(amounts) + offsets
        if self.stage is not None:
            x = self.stage(x)
        paper_amounts = np.stack(
            [np.interp(x[..., k], self.paper.log_exposure, self.paper.curves[:, k]) for k in range(3)], axis=-1)
        reflectance = 10.0 ** -(paper_amounts @ self.paper.dyes.T)
        return (reflectance @ self._observer) @ self._to_rgb.T


def exposure_per_unit(printer: Printer, amounts: np.ndarray, step: float = 1e-4) -> np.ndarray:
    """How much log10 paper exposure of layer c moves per unit of negative dye c, at `amounts`.

    The magnitude of the diagonal of d(log10 paper exposure) / d(amount) by central
    differences: c = 0 is the red layer under the cyan dye, 1 green under magenta, 2 blue
    under yellow. The manifest carries it so the app can turn stops of lab balance or
    print exposure into Print LUT input offsets.
    """
    amounts = np.asarray(amounts, dtype=float)
    out = np.empty(3)
    for k in range(3):
        delta = np.zeros(3)
        delta[k] = step
        out[k] = (printer.log_exposure(amounts + delta)[k] - printer.log_exposure(amounts - delta)[k]) / (2.0 * step)
    return np.abs(out)


def calibrate(printer: Printer, gray_amounts: np.ndarray, target: float | None = None) -> np.ndarray:
    """Filtration offsets for the print medium's reference, or an explicit linear gray target.

    Newton's method with a finite-difference Jacobian, started with every paper layer at
    the middle of its curve, solves neutral reflection prints. Print film instead times
    the negative gray to its published Laboratory Aim Density (LAD).
    """
    paper = printer.paper
    if target is None and paper.lab_aim_density is not None:
        if printer.stage is not None:
            raise CalibrationError("a print with a laboratory aim cannot use a paper tone stage")
        amounts, residual, _ = dye_amounts_for(paper.lab_aim_density, paper.base, paper.dyes, status_weights("A"))
        if np.max(np.abs(residual)) > 1e-6:
            raise CalibrationError("the print dyes cannot reproduce the Laboratory Aim Density")
        exposures = []
        for layer, amount in zip(paper.curves.T, amounts):
            crossings = np.flatnonzero((layer[:-1] <= amount) & (amount < layer[1:]))
            if len(crossings) != 1:
                raise CalibrationError("the Laboratory Aim Density requires one rising crossing per print curve")
            i = crossings[0]
            exposures.append(np.interp(amount, layer[i:i+2], paper.log_exposure[i:i+2]))
        return np.asarray(exposures) - printer.log_exposure(gray_amounts)
    if target is None:
        target = GRAY_TARGET
    middle = 0.5 * (paper.curves.min(axis=0) + paper.curves.max(axis=0))
    start = np.array([paper.log_exposure[np.argmin(np.abs(paper.curves[:, k] - middle[k]))] for k in range(3)])
    if printer.stage is not None:  # start where the stage sends mid-gray to the middle of the paper's curves
        start = printer.stage.inverse(start)
    offsets = start - printer.log_exposure(gray_amounts)
    goal = np.full(3, target)

    def error(candidate: np.ndarray) -> np.ndarray:
        return printer(gray_amounts, candidate) - goal

    residual = error(offsets)
    for _ in range(80):
        if np.max(np.abs(residual)) < 1e-10:
            break
        step_size = 1e-5
        jacobian = np.stack(
            [(error(offsets + step_size * np.eye(3)[k]) - residual) / step_size for k in range(3)], axis=1)
        try:
            step = np.clip(np.linalg.solve(jacobian, -residual), -0.3, 0.3)
        except np.linalg.LinAlgError as failure:
            raise CalibrationError("the print model has no slope at mid-gray") from failure
        scale = 1.0
        while True:
            trial = error(offsets + scale * step)
            if np.linalg.norm(trial) < np.linalg.norm(residual) or scale < 1e-4:
                break
            scale /= 2
        offsets = offsets + scale * step
        residual = trial

    if np.max(np.abs(residual)) > 1e-6:
        raise CalibrationError(
            f"mid-gray prints as {residual + goal}, not a neutral {target}; the paper may not reach it")
    return offsets


def bake_print(printer: Printer, size: int, density_range: float, offsets: np.ndarray) -> np.ndarray:
    """The Print LUT as a (size, size, size, 3) array indexed [blue][green][red].

    Input nodes are normalized negative dye amounts. Output is display-linear Rec. 2020,
    floored at zero because a print cannot give back negative light.
    """
    axis = np.linspace(0.0, 1.0, size)
    blue, green, red = np.meshgrid(axis, axis, axis, indexing="ij")
    nodes = np.stack([red, green, blue], axis=-1).reshape(-1, 3) * density_range
    out = np.empty_like(nodes)
    for start in range(0, len(nodes), CHUNK):
        out[start:start + CHUNK] = printer(nodes[start:start + CHUNK], offsets)
    return np.maximum(out, 0.0).reshape(size, size, size, 3)
