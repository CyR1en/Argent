"""The negative: scene light to dye amounts, baked into the Negative LUT.

Stages, in order:

1. and 2. From colour to layer exposure. The film's layers integrate the light's spectrum
   against their sensitivities, and the LUT sees only a colour, so the exposure is guessed
   from working-space RGB by a 3 by 3 matrix per stock, fitted to measured reflectances lit
   by the film's reference illuminant, CIE D55: Morimoto et al.'s natural objects (CC BY
   4.0) and NIST's forearms (`tools/fit_exposure_matrix.py`, docs/research/film-sim/
   bakelook.md section 2). Its rows sum to one, so equal RGB gives equal exposures and a
   neutral stays neutral at every level. A profile without a fitted matrix (the synthetic
   one) upsamples RGB to a smooth reflectance spectrum instead and integrates that
   (`reflectance_basis`), which loses chroma on real step-like spectra. The exposure is
   floored where a saturated colour would take a layer below zero. Each layer's exposure
   is divided by what a mid-gray gives it, which leaves only the layer's color response;
   its speed and balance live in the characteristic curves.
3. Placement. Mid-gray lands at 11.49 / box speed lux-seconds: a meter reading plus the
   half stop Kodak's gray-card instructions add (see `mid_gray_log_exposure`). Rated at
   is applied later, in the render graph.
4. Dye formation, one curve per layer, from log exposure to the amount of the layer's
   dye. The curves are the sheet's Status M characteristic curves inverted through the
   densitometer (`profile.py`), so the amounts are what the dyes contribute, not what a
   densitometer reads.
5. Inter-layer coupling. A layer that develops heavily inhibits its neighbors, measured
   against a neutral exposure so the gray axis is untouched and saturation rises. The
   strengths are fitted so each layer's gamma ratio, separation over neutral exposure in
   Status M, matches what Kodak's and Fuji's patents measured on commercial films
   (`gamma_ratios`, `tools/fit_couplers.py`).

The LUT stores amounts divided by a density range, so the Print LUT and the render
graph read the same normalized units. Amounts are in units of each dye's unit-peak
spectral density; the manifest's densityRange is the range of those amounts.

The gates at the end of the module check a profile against what its sheet prints: the
red density of a normally exposed gray card and of the lightest step of a paper gray
scale, the ISO 5800 speed from the curves, the unmixing fit, and the inversion. The
`check` command prints them and the tests run them over every stock.
"""

import math
from dataclasses import dataclass

import numpy as np

from .densitometry import status_density, status_weights
from .encoding import LogEncoding
from .profile import MEASURED_STATUSES, StockProfile
from .spectral import WAVELENGTHS, blackbody, cie_1931, daylight, rgb_to_xyz_matrix

# Film is balanced for daylight, and scene-linear neutrals are white balanced, so equal
# RGB is this light. Kodak's sheets say only "Daylight"; ISO 7589's sensitometric daylight is
# D55 times the ISO standard lens, and its photographic daylight is CIE D55 within 0.5 percent
# (checked against colour-science's transcription of ISO 7589:2002, docs/research/legal.md
# section 9); that Kodak uses it is inference.
REFERENCE_ILLUMINANT = daylight(5503.0)

MID_GRAY = 0.18
FILM_LOG_ENCODING = LogEncoding(stops_above_mid_gray=8.0)
# Start above diffuse white (0.18 × 2^3). The tail approaches +5.5 effective stops
# without reaching it or changing the slope at the knee.
SHOULDER_START_STOPS = 3.0
SHOULDER_WIDTH_STOPS = 2.5

# ISO 2720 reflected-light meter: exposure at mid-gray is q * K / S lux-seconds.
METER_CONSTANT = 12.5
LENS_FACTOR = 0.65
# Kodak's gray-card instructions (publication R-27): open up half a stop from a reading off
# the card for subjects of normal reflectance.
GRAY_CARD_FACTOR = math.sqrt(2.0)

# Layer exposure never goes below this fraction of mid-gray's. The LUT's own floor is
# 2^-8, so this only matters where upsampling produced a negative lobe.
RELATIVE_FLOOR = 2.0 ** -10

DENSITY_RANGE_STEP = 0.5

# Gamma ratios are read over a stop either side of mid-gray, on the straight part of every curve.
GAMMA_RATIO_HALF_RANGE = 0.3

# Keeps the basis spectra small. The tristimulus constraints hold exactly at any value;
# the ridge only chooses among the spectra that satisfy them. At 1e-6 the Rec. 2020 green
# primary dips to -4, at 1e-2 every primary stays within about -0.5 to 1.3.
SMOOTHNESS_RIDGE = 1e-2

# The gates, with the tolerances the tests and the check command apply.
GRAY_CARD_MARGIN = 0.02  # density the red curve may miss the sheet's window by
# The lightest step of a KODAK Paper Gray Scale has a nominal density of 0.1 (Kodak's product page,
# read 2026-10-07): it reflects 10^-0.1, 0.645 log H above the 18 percent card. Its window gets the
# gray card's margin plus 0.02 D for the step's nominal density, which a red gradient near 0.55
# turns into about that much density per 0.04 D of step.
WHITE_STEP_REFLECTANCE = 10.0 ** -0.1
WHITE_STEP_MARGIN = 0.04
SPEED_TOLERANCE_STOPS = 0.5  # ISO 5800 speed from the curves against the box speed
SPEED_POINT_DENSITY = 0.15  # ISO 5800: density above D-min that defines the speed point
UNMIX_RMS_LIMIT = 0.012  # density, over the sheet's dye plot
MAGENTA_TO_BLUE_LIMIT = 0.15  # Status M blue per unit magenta
CYAN_TO_GREEN_LIMIT = 0.22  # Status M green per unit cyan; the dye decomposition is not unique
INVERSION_TOLERANCE = 1e-6  # density, where no amount is pinned at zero
PINNED_TOLERANCE = 0.01  # density, in toe rows where the sheet's two plots disagree and an amount pins at zero
AMOUNT_FALL_TOLERANCE = 0.002  # amounts may fall by this plus whatever the printed curves themselves fall by


@dataclass(frozen=True)
class NegativeBake:
    lut: np.ndarray  # (size, size, size, 3), indexed [blue][green][red], normalized dye amounts
    density_range: float


@dataclass(frozen=True)
class Gate:
    name: str
    detail: str
    passed: bool


def reflectance_basis(illuminant: np.ndarray = REFERENCE_ILLUMINANT) -> np.ndarray:
    """Smooth reflectance spectra for the three Rec. 2020 primaries, as an (n, 3) array.

    Each column is a third of a flat spectrum plus the smoothest, smallest chroma term
    that gives the primary its tristimulus under `illuminant`. Equal RGB is white for that
    light, and the chroma terms cancel, so the columns sum to a flat spectrum of one.
    """
    cmf = cie_1931()
    weights = cmf * illuminant[:, None]
    weights = weights / (cmf[:, 1] @ illuminant)  # a flat reflectance of one has Y = 1
    white = weights.sum(axis=0)
    to_xyz = rgb_to_xyz_matrix(white_xyz=white)

    count = WAVELENGTHS.size
    second_difference = np.diff(np.eye(count), n=2, axis=0)
    precision = second_difference.T @ second_difference + SMOOTHNESS_RIDGE * np.eye(count)
    solved = np.linalg.solve(precision, weights)
    chroma = to_xyz - white[:, None] / 3.0
    return 1.0 / 3.0 + solved @ np.linalg.solve(weights.T @ solved, chroma)


def smooth_basis_matrix(profile: StockProfile) -> np.ndarray:
    """Layer exposure per unit of each Rec. 2020 primary through the smooth reflectance basis, rows
    scaled to sum to one: the first bake's upsampler, kept for profiles with no fitted matrix."""
    illuminant = (REFERENCE_ILLUMINANT if profile.capture_illuminant_kelvin is None
                  else blackbody(profile.capture_illuminant_kelvin))
    matrix = profile.sensitivity.T @ (illuminant[:, None] * reflectance_basis(illuminant))
    return matrix / matrix.sum(axis=1, keepdims=True)


def exposure_matrix(profile: StockProfile) -> np.ndarray:
    """Relative layer exposure per unit of each Rec. 2020 primary, (3 layers, 3 primaries), rows summing
    to one: the profile's fitted matrix, or the smooth basis's where it has none."""
    if profile.exposure_matrix is not None:
        return profile.exposure_matrix
    return smooth_basis_matrix(profile)


def mid_gray_log_exposure(box_speed: float) -> float:
    """log10 lux-seconds at which a scene mid-gray lands on a stock of this box speed: 11.49 / S.

    An ISO 2720 reflected-light meter reading (K 12.5, q 0.65) puts q K / S = 8.1 / S
    lux-seconds on the film for an 18 percent gray. Kodak's gray-card instructions
    (publication R-27) say to give half a stop more than a reading off the card for
    subjects of normal reflectance, and that half stop, GRAY_CARD_FACTOR, takes it to
    11.49 / S. Phase 1 verified that this lands the red density inside the gray-card
    window every Kodak sheet prints; the six windows intersect at H times S between 11.0
    and 11.6, so one constant serves every stock.
    """
    return math.log10(LENS_FACTOR * METER_CONSTANT * GRAY_CARD_FACTOR / box_speed)


def log_exposure(profile: StockProfile, linear_rgb: np.ndarray) -> np.ndarray:
    """Per-layer log10 exposure for scene-linear Rec. 2020 RGB with shape (..., 3)."""
    matrix = exposure_matrix(profile)
    mid_gray = MID_GRAY * matrix.sum(axis=1)
    relative = np.maximum((linear_rgb @ matrix.T) / mid_gray, RELATIVE_FLOOR)
    return mid_gray_log_exposure(profile.box_speed) + np.log10(relative)


def _amount(profile: StockProfile, layer: int, x: np.ndarray) -> np.ndarray:
    """Read one dye's curve at the effective exposure after highlight roll-off."""
    if uses_modeled_shoulder(profile):
        x = shoulder_log_exposure(x, mid_gray_log_exposure(profile.box_speed))
    return np.interp(x, profile.log_exposure, profile.amount_curves[:, layer])


def uses_modeled_shoulder(profile: StockProfile) -> bool:
    return profile.modelled_film is not None and not profile.has_published_shoulder


def shoulder_log_exposure(x: np.ndarray, mid_gray: float) -> np.ndarray:
    """A smooth, asymptotically flat continuation of the straight scene-exposure response."""
    knee = mid_gray + SHOULDER_START_STOPS * math.log10(2)
    width = SHOULDER_WIDTH_STOPS * math.log10(2)
    above = np.maximum(x - knee, 0.0)
    return np.minimum(x, knee) - width * np.expm1(-above / width)


def encoding_for(profile: StockProfile) -> LogEncoding:
    return FILM_LOG_ENCODING if profile.modelled_film is not None else LogEncoding()


def dye_amounts(profile: StockProfile, linear_rgb: np.ndarray) -> np.ndarray:
    """Amounts of the cyan, magenta and yellow dyes for scene-linear RGB (..., 3).

    Units are each dye's unit-peak spectral density; the base and mask are not included,
    they are the profile's `base` spectrum.
    """
    return layer_amounts(profile, log_exposure(profile, linear_rgb))


def layer_amounts(profile: StockProfile, x: np.ndarray) -> np.ndarray:
    """Dye amounts for per-layer log10 exposures (..., 3), red, green and blue layers, couplers applied."""
    adjusted = coupled_exposure(profile, x)
    return np.stack([_amount(profile, k, adjusted[..., k]) for k in range(3)], axis=-1)


def coupled_exposure(profile: StockProfile, x: np.ndarray) -> np.ndarray:
    if not profile.couplers.any():
        return x
    own = np.stack([_amount(profile, k, x[..., k]) for k in range(3)], axis=-1)

    adjusted = x.copy()
    for j in range(3):
        for k in range(3):
            coupling = profile.couplers[j, k]
            if j == k or coupling == 0:
                continue
            # Layer k's amount if it had been exposed like layer j, against what it got.
            neutral = _amount(profile, k, x[..., j])
            adjusted[..., j] -= coupling * (own[..., k] - neutral)
    return adjusted


def gamma_ratios(profile: StockProfile, half_range: float = GAMMA_RATIO_HALF_RANGE) -> np.ndarray:
    """Each layer's Status M gamma under a separation exposure over its gamma under white light.

    The measure Kodak's and Fuji's patents publish for colour negatives (docs/research/film.md,
    section 4.2), read here at mid-scale: the layer's exposure steps `half_range` log H either
    side of the bake's mid-gray while the other two stay at mid-gray, against all three stepping
    together, each read in the layer's own Status M channel. White light is untouched by the
    couplers, so with none the ratio is below one wherever another dye absorbs in the channel,
    and the couplers raise it.

    EP1693702 reads its gammas from 0.2 to 1.2 above fog with the other layers unexposed. That
    cannot be read on this model: a layer alone never develops more dye than the white-light
    curve's top, and alone the green record stops about 1.1 above fog. The patents find the
    ratio lower in the toe than at mid-scale (US5314792: blue 1.06 to 1.12 in the toe, 1.44 to
    1.53 at mid-scale), so matching published wide-range ratios at mid-scale errs toward too
    little interimage (inference).
    """
    weights = status_weights("M")
    mid = mid_gray_log_exposure(profile.box_speed)
    steps = np.array([mid - half_range, mid + half_range])

    def density(exposures: np.ndarray) -> np.ndarray:
        return status_density(profile.base[None, :] + layer_amounts(profile, exposures) @ profile.dyes.T, weights)

    white = density(np.repeat(steps[:, None], 3, axis=1))
    ratios = []
    for j in range(3):
        separation = np.full((2, 3), mid)
        separation[:, j] = steps
        alone = density(separation)
        ratios.append((alone[1, j] - alone[0, j]) / (white[1, j] - white[0, j]))
    return np.array(ratios)


def density_range_for(peak: float) -> float:
    """The smallest range, in steps of half a unit, that holds `peak`."""
    return max(DENSITY_RANGE_STEP, math.ceil(peak / DENSITY_RANGE_STEP - 1e-9) * DENSITY_RANGE_STEP)


def input_grid(size: int, encoding: LogEncoding) -> np.ndarray:
    """Scene-linear RGB at every LUT node, shape (size, size, size, 3), indexed [b][g][r]."""
    axis = np.linspace(0.0, 1.0, size)
    blue, green, red = np.meshgrid(axis, axis, axis, indexing="ij")
    return encoding.decode(np.stack([red, green, blue], axis=-1))


def density_range(profile: StockProfile, size: int = 65, encoding: LogEncoding | None = None) -> float:
    """The range the LUTs are normalized to: the largest amount the curves reach on the plot or the
    Negative LUT's grid reaches, rounded up.

    Keep the plotted top as headroom for lab balance and print exposure, which shift the
    Print LUT's input upward. Also check the actual LUT grid for saturated colors.
    """
    plotted = profile.amount_curves[profile.log_exposure <= profile.plotted_to + 1e-9] if profile.plotted_to is not None \
        else profile.amount_curves
    grid = dye_amounts(profile, input_grid(size, encoding if encoding is not None else encoding_for(profile)))
    return density_range_for(max(float(plotted.max()), float(grid.max())))


def lut_layer_exposure_peak(profile: StockProfile, size: int = 65, encoding: LogEncoding | None = None) -> np.ndarray:
    """Largest effective exposure read from each curve on the Negative LUT's grid, log H."""
    encoding = encoding if encoding is not None else encoding_for(profile)
    x = log_exposure(profile, input_grid(size, encoding).reshape(-1, 3))
    peak = np.maximum(x, coupled_exposure(profile, x)).max(axis=0)
    return shoulder_log_exposure(peak, mid_gray_log_exposure(profile.box_speed)) if uses_modeled_shoulder(profile) else peak


def bake_negative(profile: StockProfile, size: int, encoding: LogEncoding | None = None) -> NegativeBake:
    encoding = encoding if encoding is not None else encoding_for(profile)
    grid = dye_amounts(profile, input_grid(size, encoding))
    range_ = density_range(profile, size, encoding)
    if grid.max() > range_ + 1e-9:
        raise ValueError(f"profile {profile.id}: the couplers push an amount to {grid.max():.3f}, past the density range {range_}")
    return NegativeBake(lut=grid / range_, density_range=range_)


# The gates.

def gray_card_red_density(profile: StockProfile) -> float:
    """Status M red density of the sheet's red curve at the bake's mid-gray exposure."""
    return float(np.interp(mid_gray_log_exposure(profile.box_speed), profile.log_exposure, profile.curves[:, 0]))


def gray_card_window_ok(profile: StockProfile, margin: float = GRAY_CARD_MARGIN) -> bool:
    """Whether the mid-gray red density lies inside the sheet's gray-card window, widened by `margin`."""
    if profile.gray_card is None:
        return True
    low, high = profile.gray_card
    return low - margin <= gray_card_red_density(profile) <= high + margin


def white_step_red_density(profile: StockProfile) -> float:
    """Status M red density of the sheet's red curve where the paper gray scale's lightest step lands."""
    x = mid_gray_log_exposure(profile.box_speed) + math.log10(WHITE_STEP_REFLECTANCE / MID_GRAY)
    return float(np.interp(x, profile.log_exposure, profile.curves[:, 0]))


def white_step_window_ok(profile: StockProfile, margin: float = WHITE_STEP_MARGIN) -> bool:
    """Whether the lightest gray-scale step's red density lies inside the sheet's window, widened by `margin`."""
    if profile.white_step is None:
        return True
    low, high = profile.white_step
    return low - margin <= white_step_red_density(profile) <= high + margin


def _log_exposure_at_density(profile: StockProfile, layer: int, target: float) -> float:
    """log H where a layer's curve first reaches `target` density."""
    column = profile.curves[:, layer]
    if target > column[-1]:
        return float("nan")
    i = int(np.searchsorted(column, target))
    i = max(1, min(i, column.size - 1))
    x0, x1, y0, y1 = profile.log_exposure[i - 1], profile.log_exposure[i], column[i - 1], column[i]
    if y1 == y0:
        return float(x0)
    return float(x0 + (target - y0) * (x1 - x0) / (y1 - y0))


def iso5800_speed(profile: StockProfile) -> float:
    """ISO 5800 speed from the curves: S = sqrt(2) / sqrt(H_G H_S).

    H_G is the exposure at which the green layer reaches 0.15 above its minimum density
    and H_S the same for the slowest layer, the one that needs the most exposure to get
    there.
    """
    minimum = profile.curves.min(axis=0)
    points = [_log_exposure_at_density(profile, k, minimum[k] + SPEED_POINT_DENSITY) for k in range(3)]
    slowest = max(points)
    return math.sqrt(2.0) / 10.0 ** (0.5 * (points[1] + slowest))


def largest_amount_fall(profile: StockProfile) -> float:
    """The most any dye amount falls between consecutive samples of the inverted curves."""
    return float(max(0.0, -np.diff(profile.amount_curves, axis=0).min()))


def largest_curve_fall(profile: StockProfile) -> float:
    """The most any printed curve falls between consecutive samples."""
    return float(max(0.0, -np.diff(profile.curves, axis=0).min()))


def inversion_residuals(profile: StockProfile) -> tuple[float, float, int]:
    """(largest residual where every amount is positive, largest residual in pinned rows, pinned row count)."""
    weights = status_weights("M" if profile.densitometry == "statusM" else "A")
    reproduced = status_density(profile.base[None, :] + profile.amount_curves @ profile.dyes.T, weights)
    if profile.density_offset is not None:
        reproduced -= profile.density_offset
    residual = np.abs(reproduced - profile.curves).max(axis=1)
    pinned = (profile.amount_curves <= 0.0).any(axis=1)
    free = float(residual[~pinned].max()) if (~pinned).any() else 0.0
    held = float(residual[pinned].max()) if pinned.any() else 0.0
    return free, held, int(pinned.sum())


def check_gates(profile: StockProfile) -> list:
    """Every gate as a Gate(name, detail, passed), in the order the check command prints them.

    The ISO 5800 speed compares the curves with a box speed a sheet printed, so it is
    informational for a synthetic profile; the cross-talk limits bound the unmixing prior,
    so they are informational when the dyes were given explicitly.
    """
    gates = []
    measured = profile.status in MEASURED_STATUSES
    verify_speed = measured and profile.speed_reference
    informational = "; informational for status " + profile.status
    mid = mid_gray_log_exposure(profile.box_speed)
    red = gray_card_red_density(profile)
    if profile.gray_card is None:
        gates.append(Gate("gray card", f"mid-gray at log H {mid:.4f}, red density {red:.3f}, no window in the profile", True))
    else:
        low, high = profile.gray_card
        gates.append(Gate("gray card",
                          f"mid-gray at log H {mid:.4f}, red density {red:.3f}, window {low:.2f} to {high:.2f} "
                          f"widened by {GRAY_CARD_MARGIN:.2f}", bool(gray_card_window_ok(profile))))
    white = white_step_red_density(profile)
    if profile.white_step is None:
        gates.append(Gate("white step", f"lightest gray-scale step at red density {white:.3f}, no window in the profile", True))
    else:
        low, high = profile.white_step
        gates.append(Gate("white step",
                          f"lightest gray-scale step (density 0.1) at red density {white:.3f}, window {low:.2f} to "
                          f"{high:.2f} widened by {WHITE_STEP_MARGIN:.2f}", bool(white_step_window_ok(profile))))
    if not profile.speed_reference:
        gates.append(Gate("ISO 5800 speed", "published plot is not a speed reference", True))
    else:
        speed = iso5800_speed(profile)
        stops = math.log2(speed / profile.box_speed) if speed > 0 and math.isfinite(speed) else float("nan")
        speed_ok = bool(math.isfinite(stops) and abs(stops) <= SPEED_TOLERANCE_STOPS)
        gates.append(Gate("ISO 5800 speed",
                          f"{speed:.0f} from the curves against box {profile.box_speed:.0f} ({stops:+.2f} stops)"
                          + ("" if verify_speed else informational), speed_ok if verify_speed else True))
    model = profile.negative_model or {}
    rms = model.get("rms")
    unmixed = rms is not None
    if unmixed:
        gates.append(Gate("unmixing", f"rms {rms:.4f} D, max {model['maxError']:.4f} D at {model.get('maxErrorWavelength', 0):.0f} nm",
                          bool(rms < UNMIX_RMS_LIMIT)))
    else:
        gates.append(Gate("unmixing", "explicit dye spectra, no fit", True))
    cross = np.asarray(model.get("crossTalk"), dtype=float)
    cross_ok = bool(cross[2, 1] < MAGENTA_TO_BLUE_LIMIT and cross[1, 0] < CYAN_TO_GREEN_LIMIT)
    gates.append(Gate("cross-talk",
                      f"Status M blue per unit magenta {cross[2, 1]:.3f} (limit {MAGENTA_TO_BLUE_LIMIT}), "
                      f"green per unit cyan {cross[1, 0]:.3f} (limit {CYAN_TO_GREEN_LIMIT})"
                      + ("" if unmixed else "; informational, the dyes are explicit"),
                      cross_ok if unmixed else True))
    free, held, pinned = inversion_residuals(profile)
    gates.append(Gate("inversion",
                      f"residual {free:.1e} D where every amount is positive; {pinned} toe rows with an amount pinned "
                      f"at zero, residual {held:.1e} D there",
                      bool(free < INVERSION_TOLERANCE and held < PINNED_TOLERANCE)))
    fall = largest_amount_fall(profile)
    allowed = AMOUNT_FALL_TOLERANCE + largest_curve_fall(profile)
    gates.append(Gate("monotonic amounts",
                      f"amounts never fall by more than {fall:.4f} (allowed {allowed:.4f}, the printed curves fall by "
                      f"{largest_curve_fall(profile):.4f}); minimum amount {profile.amount_curves.min():.4f}",
                      bool(fall <= allowed and profile.amount_curves.min() >= 0.0)))
    plotted = profile.amount_curves[profile.log_exposure <= (profile.plotted_to if profile.plotted_to is not None else np.inf) + 1e-9]
    lut_peak = float(dye_amounts(profile, input_grid(65, encoding_for(profile))).max())
    gates.append(Gate("density range", f"largest amount {float(plotted.max()):.3f} on the plot, {lut_peak:.3f} on the "
                      f"Negative LUT's grid, densityRange {density_range(profile):.1f}", True))
    return gates
