"""Acceptance checks for the print stage, written before any candidate was measured (work package E,
docs/research/film-sim/print.md section 3). Every threshold is a published number or first principles:

Per stock and print setup (a paper, optionally a lab's tone stage):
- tone: after the best uniform shift of scene density, the print's perceived density stays within 0.10 D of
  the reference figure over US5300381's mid-tone range, scene density 0.60 to 1.45 (col. 2). The reference
  is FIG. 2, "a typical professional film/paper system", for the KODAK PROFESSIONAL stocks Kodak places
  at the low end of its contrast bar (the three Portras), and FIG. 1, "a typical amateur film/paper system",
  for the consumer stocks (Gold 200, UltraMax 400). 0.10 D is Kodak's RA-4 control limit on a print's
  low-density patch and on its high-minus-low contrast (Z-130 section 7, Table 7-1): beyond it "results will
  be unsatisfactory for color, density, and/or contrast".
- mid-tone slope: the mean perceived gradient over 0.60 to 1.45, after the same shift, within 0.12 of the
  figure's: the same 0.10 D control limit on a density difference, spread over the range's 0.85.
  Ektar 100: Kodak's catalogue and brochure draw its contrast above the Portras' (0.55 against 0.27 of the
  bar), so FIG. 2 bounds it from below only (slope at least FIG. 2's less 0.12) and its tone is not gated.
- US7372597: the largest d L* / d L* as perceived; reported for a paper (the patent says conventional prints
  fall outside its band), required between 1.5 and 2.0 for a lab's tone stage, which is what it bounds.
- the KODAK Paper Gray Scale, density 0.10 to 1.75 in twelve steps: adjacent steps at least 0.02 D apart in
  the print's visual density, the smallest density difference Kodak's RA-4 process control acts on (the D-min
  limit, Z-130 Table 7-1). (Corrected before any candidate but the status quo was measured, print.md section 3.)
- D-max: each channel's Status A density at the deepest the scale reaches at least the lowest starting
  D-max aim of the paper's CIS sheet less 0.15, Kodak's control limit on the black patch (Z-130 Table 7-1);
  reported against the highest aim.
- the neutral axis: every gray-scale step whose L* is at least 20 within C*ab 2 of neutral (CIELAB against
  paper white, D65): two just-noticeable differences; E-4070 claims a "Neutral tone scale".
- highlights: the ColorChecker's white, neutral 8 and neutral 6.5 at 4, 5 and 6 stops over, the printer
  re-balanced on the frame's mid-gray, at least 1 L* apart (work package A1's separation kept).
- the negative's gates (gray card, white step) still pass: they do not depend on the print, so this
  confirms nothing moved there.
Across the six stocks with their setups: Kodak's saturation order 160 < 400 < 800 < Ektar 100 (Portra 800
0.015 above 400), the six-stock order of film.md 4.2, the contrast order (the Portras within 5 percent of
each other, Ektar at least 5 percent above the steepest), the granularity order (the print does not touch it).
"""

from dataclasses import dataclass

import numpy as np

from .checker import COLOURED, D65, NEUTRAL_5, TO_XYZ, scene, xyz_to_lab
from .negative import MID_GRAY, check_gates, dye_amounts
from .paper import paper_named
from .print_tone import FIGURE_SCENE, FIGURES, GRAY_SCALE, MIDTONE, SCENE, US7372597_BAND, figure_midtone_slope, print_tone
from .printing import GRAY_TARGET, Printer, ToneStage, calibrate

CONTROL_LIMIT = 0.10  # D, Kodak Z-130 Table 7-1, LD and HD - LD control limits
SLOPE_TOLERANCE = CONTROL_LIMIT / (MIDTONE[1] - MIDTONE[0])
BLACK_PATCH_LIMIT = 0.15  # D, Z-130 Table 7-1, the black patch's control limit (below aim)
GRAY_STEP_DENSITY = 0.02  # D, the smallest limit in Kodak's RA-4 process control (D-min, +0.02; Z-130 Table 7-1)
NEUTRAL_CHROMA = 2.0
NEUTRAL_FROM_LSTAR = 20.0
HIGHLIGHT_LSTAR = 1.0

# The figure each stock's tone is held to, and how (print.md section 3).
REFERENCE = {
    "kodak-portra-160": ("FIG. 2", "match"),
    "kodak-portra-400": ("FIG. 2", "match"),
    "kodak-portra-800": ("FIG. 2", "match"),
    "kodak-ektar-100": ("FIG. 2", "at least"),
    "kodak-gold-200": ("FIG. 1", "match"),
    "kodak-ultramax-400": ("FIG. 1", "match"),
}

# Starting D-max aims for digital printers, Status A red, green, blue, lowest and highest over the printers
# each CIS sheet lists (print.md section 1.2).
DMAX_AIMS = {
    "kodak-endura-premier": ((2.25, 2.20, 2.15), (2.45, 2.45, 2.40)),  # CIS-289, 2011-10
    "kodak-portra-endura": ((2.08, 2.05, 2.05), (2.25, 2.25, 2.15)),  # CIS-234, 2007-04
    "kodak-supra-endura": ((2.25, 2.15, 2.15), (2.40, 2.35, 2.25)),  # CIS-235, 2007-04
    "kodak-supra-endura-vc-digital": ((2.25, 2.20, 2.15), (2.50, 2.50, 2.40)),  # CIS-283, 2008-07
}

PATCHES = (18, 19, 20)  # the ColorChecker's white, neutral 8, neutral 6.5


@dataclass(frozen=True)
class Check:
    name: str
    passed: bool | None  # None: reported, not a pass or fail for this setup
    detail: str


@dataclass(frozen=True)
class Setup:
    paper: str
    stage: ToneStage | None = None

    @property
    def label(self) -> str:
        return self.paper + (f" + {self.stage.name}" if self.stage is not None else "")


def figure_stage(profile, paper, figure: str | None = None):
    """The tone stage for a stock: built from the figure its tone is held to (print_stage.py)."""
    from .print_stage import figure_stage as build
    return build(profile, paper, figure or REFERENCE[profile.id][0])


def setup_for(profile) -> Setup:
    """The print setup a profile names: its paper and, if it names one, its tone stage."""
    from .print_stage import stage_for
    return Setup(profile.paper, stage_for(profile, paper_named(profile.paper)))


def _printer(profile, setup: Setup):
    return Printer(paper_named(setup.paper), profile.dyes, profile.base, stage=setup.stage)


def render(profile, setup: Setup, rgb: np.ndarray, rebalance: np.ndarray | None = None) -> np.ndarray:
    """CIELAB under D65 of the print, paper white at L* 100 (checker.render with a chosen setup)."""
    printer = _printer(profile, setup)
    gray = np.full(3, MID_GRAY) if rebalance is None else rebalance
    offsets = calibrate(printer, dye_amounts(profile, gray))
    out = np.array([printer(dye_amounts(profile, colour), offsets) for colour in rgb])
    return xyz_to_lab(out @ TO_XYZ.T, D65)


def chroma_ratio(profile, setup: Setup) -> float:
    """The saturation tests' measure: mean over the 18 coloured patches of print C* over scene C*."""
    rgb, scene_lab = scene()
    lab = render(profile, setup, rgb)
    return float(np.mean(np.hypot(lab[COLOURED, 1], lab[COLOURED, 2]) / np.hypot(scene_lab[COLOURED, 1],
                                                                                scene_lab[COLOURED, 2])))


def lstar_per_stop(profile, setup: Setup) -> float:
    """The contrast test's measure: print L* per stop at mid-gray, half a stop either side."""
    lab = render(profile, setup, np.array([np.full(3, MID_GRAY * 2.0 ** e) for e in (-0.5, 0.5)]))
    return float(lab[1, 0] - lab[0, 0])


def check_stock(profile, setup: Setup) -> list:
    figure, how = REFERENCE[profile.id]
    tone = print_tone(profile, paper_named(setup.paper), setup.stage, figure)
    checks = []

    reference = FIGURES[figure]
    shifted = np.interp(SCENE + tone.best_shift, SCENE, tone.perceived)
    inside = (SCENE >= MIDTONE[0]) & (SCENE <= MIDTONE[1])
    deviation = float(np.max(np.abs(shifted[inside] - np.interp(SCENE[inside], FIGURE_SCENE, reference))))
    detail = (f"largest deviation from {figure} over scene density 0.60 to 1.45 after a shift of {tone.best_shift:+.2f}: "
              f"{deviation:.3f} D (limit {CONTROL_LIMIT}); rms over 0 to 2 {tone.rms_shifted:.3f} D")
    checks.append(Check("tone", deviation <= CONTROL_LIMIT if how == "match" else None, detail))

    target = figure_midtone_slope(figure)
    slope = tone.midtone_slope_shifted
    if how == "match":
        ok = abs(slope - target) <= SLOPE_TOLERANCE
        limit = f"{target - SLOPE_TOLERANCE:.2f} to {target + SLOPE_TOLERANCE:.2f}"
    else:
        ok = slope >= target - SLOPE_TOLERANCE
        limit = f"at least {target - SLOPE_TOLERANCE:.2f}"
    checks.append(Check("mid-tone slope", ok, f"{slope:.2f} after the shift, {tone.midtone_slope:.2f} as placed "
                                              f"({figure}: {target:.2f}; {limit})"))

    low, high = US7372597_BAND
    gamma = tone.max_lstar_gamma_flare
    checks.append(Check("US7372597", (low <= gamma <= high) if setup.stage is not None else None,
                        f"largest dL*/dL* as perceived {gamma:.2f} ({low} to {high}; required of a tone stage)"))

    steps = np.diff(tone.gray_scale)
    lstar = np.diff(-tone.gray_scale_lstar)
    checks.append(Check("gray scale", bool(np.all(steps >= GRAY_STEP_DENSITY)),
                        f"smallest step {steps.min():.3f} D in print visual density (at least {GRAY_STEP_DENSITY}); "
                        f"{lstar.min():.2f} L* as perceived"))

    aims = DMAX_AIMS.get(setup.paper)
    if aims is None:
        checks.append(Check("D-max", None, f"Status A {np.round(tone.dmax_status_a, 2)}; no CIS aims for this paper"))
    else:
        floor = np.array(aims[0]) - BLACK_PATCH_LIMIT
        checks.append(Check("D-max", bool(np.all(tone.dmax_status_a >= floor)),
                            f"Status A {' '.join(f'{v:.2f}' for v in tone.dmax_status_a)}; aims "
                            f"{'/'.join(f'{a:.2f}' for a in aims[0])} to {'/'.join(f'{a:.2f}' for a in aims[1])}, "
                            f"at least {'/'.join(f'{v:.2f}' for v in floor)}"))

    rgb = np.repeat((10.0 ** -GRAY_SCALE)[:, None], 3, axis=1)
    lab = render(profile, setup, rgb)
    chroma = np.hypot(lab[:, 1], lab[:, 2])
    seen = lab[:, 0] >= NEUTRAL_FROM_LSTAR
    checks.append(Check("neutral axis", bool(np.all(chroma[seen] <= NEUTRAL_CHROMA)),
                        f"largest C*ab {chroma[seen].max():.2f} at L* >= {NEUTRAL_FROM_LSTAR:.0f} (at most "
                        f"{NEUTRAL_CHROMA}); {chroma[~seen].max() if (~seen).any() else 0:.2f} below"))

    chart, _ = scene()
    gaps = []
    for stops in (4, 5, 6):
        lab = render(profile, setup, chart[list(PATCHES)] * 2.0 ** stops, rebalance=np.full(3, MID_GRAY * 2.0 ** stops))
        gaps += [lab[0, 0] - lab[1, 0], lab[1, 0] - lab[2, 0]]
    checks.append(Check("highlights", bool(min(gaps) >= HIGHLIGHT_LSTAR),
                        f"white, neutral 8, neutral 6.5 at +4 to +6 stops: smallest gap {min(gaps):.1f} L* "
                        f"(at least {HIGHLIGHT_LSTAR})"))

    gates = {g.name: g for g in check_gates(profile)}
    checks.append(Check("gray card and white step", gates["gray card"].passed and gates["white step"].passed,
                        f"{gates['gray card'].detail}; {gates['white step'].detail}"))
    return checks


def check_orders(stocks: dict, setups: dict) -> list:
    """Kodak's orders across the stocks, keyed by the bake's stock names (portra400, ...)."""
    chroma = {name: chroma_ratio(stocks[name], setups[name]) for name in stocks}
    slope = {name: lstar_per_stop(stocks[name], setups[name]) for name in stocks}
    checks = [Check("saturation, Kodak's catalogue and brochure",
                    chroma["portra160"] < chroma["portra400"] and chroma["portra400"] + 0.015 < chroma["portra800"]
                    < chroma["ektar100"],
                    "chroma over scene " + ", ".join(f"{n} {chroma[n]:.3f}" for n in ("portra160", "portra400",
                                                                                       "portra800", "ektar100")))]
    checks.append(Check("saturation, film.md 4.2",
                        chroma["portra160"] < min(chroma["portra400"], chroma["portra800"])
                        and max(chroma["portra400"], chroma["portra800"]) < min(chroma["gold200"], chroma["ultramax400"])
                        and max(chroma["gold200"], chroma["ultramax400"]) < chroma["ektar100"],
                        ", ".join(f"{n} {chroma[n]:.3f}" for n in ("gold200", "ultramax400"))))
    portras = [slope[n] for n in ("portra160", "portra400", "portra800")]
    checks.append(Check("contrast", (max(portras) - min(portras)) / min(portras) < 0.05
                        and slope["ektar100"] > max(portras) * 1.05,
                        "print L* per stop " + ", ".join(f"{n} {slope[n]:.2f}" for n in ("portra160", "portra400",
                                                                                         "portra800", "ektar100"))))
    rms = {name: stocks[name].grain_rms48 for name in ("portra160", "portra400", "portra800", "ektar100")}
    checks.append(Check("granularity", all(rms["portra800"][k] > rms["portra400"][k] > rms["portra160"][k]
                                           > rms["ektar100"][k] for k in range(3)), "the profiles' RMS granularity"))
    return checks
