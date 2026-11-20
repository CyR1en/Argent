"""A lab's tone stage built from a published film/paper system (docs/research/film-sim/print.md section 4).

A digital printer maps each colour record's printing density to paper exposure through a stored curve per
film type (Fuji's US6081343 and US6160634; Kodak's US7372597 cols. 15 and 16). Here the curve is built so a
neutral scale through the stock's own negative prints, on the chosen paper, the perceived density of US5300381's
FIG. 2 (or FIG. 1), a curve published as numbers in a drawing:

1. The target, as a function of scene density s: the figure's D' shifted along s so mid-gray (scene density
   0.745) prints where the daylight reference puts it (GRAY_TARGET of paper white, seen with the flare below),
   so the stage takes the figure's shape and leaves print exposure where it is (print.md section 3).
2. The flare: the one that takes the paper's own deepest neutral to the figure's D-max (as the tone check
   does), so the stage's black is the paper's black.
3. For each s, the three paper exposures at which the paper prints a neutral (equal display RGB, as the
   daylight reference defines it) of that density; the stage maps the negative's printing density at s to
   them, per layer. Colours pass through the same three maps.
"""

import numpy as np

from .negative import MID_GRAY, dye_amounts
from .print_tone import FIGURE_SCENE, FIGURES, SCENE
from .printing import GRAY_TARGET, Printer, ToneStage
from .spectral import cie_1931


def _paper_rgb(printer: Printer, x: np.ndarray) -> np.ndarray:
    """Display-linear Rec. 2020 (paper white 1) for paper log exposures x (..., 3), past any stage."""
    paper = printer.paper
    amounts = np.stack([np.interp(x[..., k], paper.log_exposure, paper.curves[:, k]) for k in range(3)], axis=-1)
    reflectance = 10.0 ** -(amounts @ paper.dyes.T)
    return (reflectance @ printer._observer) @ printer._to_rgb.T


def _neutral_exposure(printer: Printer, level: float, start: np.ndarray) -> np.ndarray:
    """Paper log exposures that print (level, level, level); Newton from `start`."""
    x = start.copy()
    goal = np.full(3, level)
    lo, hi = printer.paper.log_exposure[0], printer.paper.log_exposure[-1]
    for _ in range(60):
        residual = _paper_rgb(printer, x) - goal
        if np.max(np.abs(residual)) < 1e-9:
            break
        jacobian = np.stack([(_paper_rgb(printer, x + 1e-5 * np.eye(3)[k]) - goal - residual) / 1e-5
                             for k in range(3)], axis=1)
        damping = 1e-6 * np.eye(3)  # a layer at its flat toe or shoulder has no slope
        step = np.linalg.solve(jacobian.T @ jacobian + damping, -jacobian.T @ residual)
        x = np.clip(x + np.clip(step, -0.2, 0.2), lo, hi)
    return x


def figure_stage(profile, paper, figure: str = "FIG. 2", target: float = GRAY_TARGET) -> ToneStage:
    printer = Printer(paper, profile.dyes, profile.base)
    base = paper.base if paper.base is not None else np.zeros_like(paper.viewing)
    ybar = cie_1931()[:, 1] * paper.viewing
    white = -np.log10((10.0 ** -base) @ ybar / ybar.sum())  # paper white's visual density

    # The paper's deepest neutral: the darkest level it can print with equal RGB.
    top = paper.log_exposure[-1] * np.ones(3)
    darkest = float(np.max(_paper_rgb(printer, top)))
    black = white - np.log10(darkest)
    dmax = float(FIGURES[figure].max())
    flare = 10.0 ** -dmax - 10.0 ** -black

    def perceived(visual):
        return -np.log10(10.0 ** -visual + flare)

    mid = perceived(white - np.log10(target))
    shift = float(np.interp(mid, FIGURES[figure], FIGURE_SCENE)) - (-np.log10(MID_GRAY))
    scene = SCENE
    wanted = np.interp(scene + shift, FIGURE_SCENE, FIGURES[figure])
    visual = -np.log10(np.maximum(10.0 ** -wanted - flare, 1e-12))
    visual = np.clip(visual, white + 1e-4, black - 0.01)  # just inside what the paper can print as a neutral
    levels = 10.0 ** -(visual - white)

    amounts = dye_amounts(profile, np.repeat((10.0 ** -scene)[:, None], 3, axis=1))
    printing = printer.log_exposure(amounts)  # the negative's printing density, no filtration
    order = np.argsort(np.abs(scene - (-np.log10(MID_GRAY))))  # solve outward from mid-gray
    exposures = np.empty_like(printing)
    middle = 0.5 * (paper.curves.min(axis=0) + paper.curves.max(axis=0))
    guess = np.array([paper.log_exposure[np.argmin(np.abs(paper.curves[:, k] - middle[k]))] for k in range(3)])
    start = _neutral_exposure(printer, target, guess)
    solved = {}
    for i in order:
        near = min(solved, key=lambda j: abs(j - i)) if solved else None
        exposures[i] = _neutral_exposure(printer, levels[i], start if near is None else solved[near])
        solved[i] = exposures[i]
    # Where the negative is flat (beyond its toe) the stage's input stops rising: keep it increasing by a
    # negligible ramp so the map stays a function; the target there is the paper's black anyway.
    ramp = 1e-7 * np.arange(len(scene))[:, None]
    knots_in = np.maximum.accumulate(printing, axis=0) + ramp
    return ToneStage(knots_in, np.maximum.accumulate(exposures, axis=0), f"tone stage from US5300381 {figure}")


def stage_for(profile, paper) -> ToneStage | None:
    """The tone stage a profile names (its `printStage`), built for its own negative on `paper`; None if none."""
    if not getattr(profile, "print_stage", None):
        return None
    return figure_stage(profile, paper, profile.print_stage.replace("US5300381 ", ""))
