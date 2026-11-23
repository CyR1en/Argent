"""The print's tone curve against Kodak's published film/paper systems (docs/research/film-sim/print.md section 3).

A neutral scale, scene density -0.6 to 2.6 against a 100 percent diffuse white (mid-gray at 0.745), goes
through the stock's negative and a print setup (a paper, and optionally a lab's tone stage) at the daylight
reference filtration (mid-gray to GRAY_TARGET of paper white) and is read as the print's visual density,
-log10 Y under the paper's viewing light against a perfect diffuser (measure.md section 3.1).

The references, both from Kodak's US5300381 (Buhr and Franchino, 1994), measured tone reproduction "as
perceived" of a conventional negative film printed on paper:
- FIG. 1, "a typical amateur film/paper system";
- FIG. 2, "a typical professional film/paper system".
Both digitized every 0.05 of scene density from the patent's drawing sheets by tools/digitize_us5300381.py
(the solid curves; line width 0.015 D; FIG. 2 agrees with measure.md's 13 points read by eye within 0.006 D).
FIG. 2's dashed gradient curve crosses the solid one at scene density about -0.01; the tool's tracker rode the
dash from -0.022 to +0.008 and read 0.150 at 0.0, between 0.138 and 0.147, a fall no print curve makes. That
point is read by hand from the drawing (2026-11-23): the solid line's lower edge, which the dash does not touch
in that column, plus half the line's width gives 0.142, and the lone columns either side, 0.137 at -0.031 and
0.143 at +0.012, put it at 0.141; 0.142 is kept, within 0.0005 D of its neighbours' interpolation. Before that
correction the fall became a flat stretch in the Portras' tone stage, and their highlights lost order 2.5 stops
over mid-gray. "As perceived" includes viewing flare, so the print gets a flare that takes its D-max to the
figure's (-log10(10^-D + f), first principles).

And Kodak's US7372597: the largest gamma, d L*(reproduction, visually perceived) / d L*(scene), lies between
1.5 and 2.0 in its preferred digital tonescales (col. 10, claim 1); L* from Y against a perfect diffuser
(Eq. 1), so here absolute and with the same flare. The patent says conventional S-shaped prints fall outside
it (col. 3, col. 10).
"""

from dataclasses import dataclass

import numpy as np

from .densitometry import status_density, status_weights
from .negative import MID_GRAY, dye_amounts
from .paper import paper_named
from .printing import GRAY_TARGET, Printer, ToneStage, calibrate
from .profile import StockProfile
from .spectral import cie_1931

# US5300381 FIG. 1 and FIG. 2, D and D' as perceived, every 0.05 of scene density from -0.6 to 2.4.
FIGURE_SCENE = np.round(np.arange(-0.6, 2.4001, 0.05), 2)
FIG1_PRINT = np.array([
    0.119, 0.120, 0.120, 0.121, 0.122, 0.122, 0.124, 0.126, 0.128, 0.130, 0.133, 0.136, 0.141, 0.145, 0.151, 0.157,
    0.163, 0.175, 0.204, 0.231, 0.263, 0.299, 0.338, 0.386, 0.438, 0.500, 0.574, 0.659, 0.746, 0.840, 0.946, 1.051,
    1.157, 1.248, 1.351, 1.445, 1.532, 1.607, 1.677, 1.744, 1.800, 1.839, 1.877, 1.911, 1.941, 1.962, 1.978, 1.991,
    1.998, 2.006, 2.014, 2.022, 2.027, 2.034, 2.039, 2.043, 2.046, 2.048, 2.050, 2.052, 2.051])
FIG2_PRINT = np.array([
    0.119, 0.119, 0.120, 0.121, 0.122, 0.124, 0.125, 0.128, 0.129, 0.132, 0.134, 0.138, 0.142, 0.147, 0.153, 0.162,
    0.179, 0.204, 0.236, 0.274, 0.318, 0.364, 0.414, 0.472, 0.535, 0.608, 0.680, 0.751, 0.815, 0.879, 0.948, 1.027,
    1.110, 1.198, 1.284, 1.370, 1.451, 1.523, 1.587, 1.650, 1.707, 1.768, 1.826, 1.864, 1.893, 1.914, 1.933, 1.942,
    1.950, 1.959, 1.965, 1.973, 1.978, 1.984, 1.989, 1.993, 1.996, 2.000, 2.001, 2.001, 2.003])
FIGURES = {"FIG. 1": FIG1_PRINT, "FIG. 2": FIG2_PRINT}
MIDTONE = (0.60, 1.45)  # "the mid-tone range ... from about 0.6 to about 1.45" (US5300381 col. 2)
US7372597_BAND = (1.5, 2.0)
# The KODAK Paper Gray Scale: twelve steps, density 0.10 to 1.75 in 0.15 (Kodak's product page; film.md 4.1).
GRAY_SCALE = 0.10 + 0.15 * np.arange(12)
MID_GRAY_DENSITY = -np.log10(MID_GRAY)

SCENE = np.round(np.arange(-0.6, 2.61, 0.01), 3)
SPAN = (SCENE >= 0.0) & (SCENE <= 2.0)
SHIFTS = np.round(np.arange(-0.6, 0.61, 0.01), 3)


def figure_dmax(figure: str) -> float:
    return float(FIGURES[figure].max())


def figure_midtone_slope(figure: str) -> float:
    d = FIGURES[figure]
    lo, hi = MIDTONE
    return float((np.interp(hi, FIGURE_SCENE, d) - np.interp(lo, FIGURE_SCENE, d)) / (hi - lo))


@dataclass(frozen=True)
class PrintTone:
    figure: str  # the figure the shape is compared with
    visual: np.ndarray  # print visual density on SCENE, no flare
    perceived: np.ndarray  # the same with the viewing flare
    status_a: np.ndarray  # (SCENE, 3) the print's Status A densities, no flare
    gray_scale: np.ndarray  # print visual density of each gray-scale step, no flare
    gray_scale_lstar: np.ndarray  # L* of each step as perceived, against a perfect diffuser
    mid_gray: float  # print visual density of mid-gray, no flare
    mid_gray_flare: float  # the same with the viewing flare
    flare: float  # the viewing flare, a fraction of white, that takes D-max to the figure's
    mid_gradient: float  # print density per scene density over 0.60 to 0.75, with flare
    peak_gradient: float  # largest over scene 0 to 2, with flare
    midtone_slope: float  # mean gradient over the patent's mid-tone range, 0.60 to 1.45, as placed
    midtone_slope_shifted: float  # the same after the best shift
    rms: float  # D over scene 0 to 2 against the figure, with flare, as is
    rms_shifted: float  # after the best uniform scene-density shift
    best_shift: float  # that shift of scene density, D; negative: the print reads as a lighter scene would
    max_lstar_gamma: float  # largest dL*/dL*, absolute, no flare
    max_lstar_gamma_flare: float  # the same as perceived: US7372597's quantity
    max_lstar_gamma_paper: float  # against paper white, no flare
    dmax_status_a: np.ndarray  # (3,) the deepest the print goes on the scale, Status A

    # The names the earlier report used, against FIG. 2.
    @property
    def rms_to_fig2(self) -> float:
        return self.rms

    @property
    def rms_to_fig2_shifted(self) -> float:
        return self.rms_shifted


def _lstar(y):
    y = np.asarray(y, dtype=float)
    return np.where(y > 216 / 24389, 116 * np.cbrt(y) - 16, 24389 / 27 * y)


def print_tone(profile: StockProfile, paper=None, stage: ToneStage | None = None, figure: str = "FIG. 2",
               target: float = GRAY_TARGET) -> PrintTone:
    paper = paper_named(profile.paper) if paper is None else paper
    printer = Printer(paper, profile.dyes, profile.base, stage=stage)
    offsets = calibrate(printer, dye_amounts(profile, np.full(3, MID_GRAY)), target)
    amounts = dye_amounts(profile, np.repeat((10.0 ** -SCENE)[:, None], 3, axis=1))
    x = printer.log_exposure(amounts) + offsets
    if stage is not None:
        x = stage(x)
    layers = np.stack([np.interp(x[:, k], paper.log_exposure, paper.curves[:, k]) for k in range(3)], axis=-1)
    base = paper.base if paper.base is not None else np.zeros_like(paper.viewing)
    density = base + layers @ paper.dyes.T
    ybar = cie_1931()[:, 1] * paper.viewing
    visual = -np.log10((10.0 ** -density) @ ybar / ybar.sum())
    paper_white = -np.log10((10.0 ** -base) @ ybar / ybar.sum())
    status_a = status_density(density, status_weights("A"))

    reference = FIGURES[figure]
    flare = 10.0 ** -figure_dmax(figure) - 10.0 ** -visual.max()
    perceived = -np.log10(10.0 ** -visual + flare)
    gradient = np.gradient(perceived, SCENE)
    fig = np.interp(SCENE[SPAN], FIGURE_SCENE, reference)
    errors = np.array([np.sqrt(np.mean((np.interp(SCENE[SPAN] + s, SCENE, perceived) - fig) ** 2)) for s in SHIFTS])
    best = float(SHIFTS[int(np.argmin(errors))])

    def midtone(shift):
        lo, hi = MIDTONE
        return float((np.interp(hi + shift, SCENE, perceived) - np.interp(lo + shift, SCENE, perceived)) / (hi - lo))

    scene_l = _lstar(10.0 ** -SCENE)
    usable = (scene_l > 5) & (scene_l < 100)
    gamma = np.gradient(_lstar(10.0 ** -visual), scene_l)
    gamma_flare = np.gradient(_lstar(10.0 ** -perceived), scene_l)
    gamma_paper = np.gradient(_lstar(10.0 ** -(visual - paper_white)), scene_l)
    return PrintTone(
        figure=figure,
        visual=visual,
        perceived=perceived,
        status_a=status_a,
        gray_scale=np.interp(GRAY_SCALE, SCENE, visual),
        gray_scale_lstar=_lstar(10.0 ** -np.interp(GRAY_SCALE, SCENE, perceived)),
        mid_gray=float(np.interp(MID_GRAY_DENSITY, SCENE, visual)),
        mid_gray_flare=float(np.interp(MID_GRAY_DENSITY, SCENE, perceived)),
        flare=float(flare),
        mid_gradient=float(gradient[(SCENE >= 0.60) & (SCENE <= 0.75)].mean()),
        peak_gradient=float(gradient[SPAN].max()),
        midtone_slope=midtone(0.0),
        midtone_slope_shifted=midtone(best),
        rms=float(errors[np.argmin(np.abs(SHIFTS))]),
        rms_shifted=float(errors.min()),
        best_shift=best,
        max_lstar_gamma=float(gamma[usable].max()),
        max_lstar_gamma_flare=float(gamma_flare[usable].max()),
        max_lstar_gamma_paper=float(gamma_paper[usable].max()),
        dmax_status_a=status_a.max(axis=0),
    )


def report_lines(tone: PrintTone) -> list:
    """The report as the check command prints it."""
    low, high = US7372597_BAND
    fig = tone.figure
    return [
        f"print tone (docs/research/film-sim/print.md section 3), against US5300381 {fig}:",
        "  KODAK Paper Gray Scale 0.10 to 1.75 prints at visual density "
        + " ".join(f"{v:.2f}" for v in tone.gray_scale),
        f"  mid-gray prints at {tone.mid_gray:.3f}, {tone.mid_gray_flare:.3f} with a viewing flare of "
        f"{tone.flare:.4f} ({fig}: {np.interp(0.745, FIGURE_SCENE, FIGURES[fig]):.3f})",
        f"  mid-tone slope over scene density 0.60 to 1.45: {tone.midtone_slope:.2f}, {tone.midtone_slope_shifted:.2f} "
        f"after the best shift ({fig}: {figure_midtone_slope(fig):.2f}); peak {tone.peak_gradient:.2f}",
        f"  rms to {fig} over scene density 0 to 2: {tone.rms:.3f} D, {tone.rms_shifted:.3f} D after a shift of "
        f"{tone.best_shift:+.2f} D",
        f"  largest dL*/dL* {tone.max_lstar_gamma_flare:.2f} as perceived, {tone.max_lstar_gamma:.2f} without flare, "
        f"{tone.max_lstar_gamma_paper:.2f} against paper white (US7372597: {low} to {high})",
    ]
