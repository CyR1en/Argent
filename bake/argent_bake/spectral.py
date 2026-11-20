"""Spectral helpers for the bake: the wavelength grid, the CIE 1931 observer, daylight and
blackbody illuminants, resampling, and the Rec. 2020 matrices.

The colour-matching functions are CIE's own 1931 2 degree table and the D series
illuminants are computed from CIE's S0, S1 and S2 components with the CIE 15:2004 formula.
Both tables ship in `data/` as CC BY-SA 4.0 third-party data (see `data/README.md`) and are
loaded through `importlib.resources`. No stand-ins remain: `blackbody` describes the
enlarger lamp, which is physically near-Planckian.
"""

from functools import lru_cache
from importlib import resources

import numpy as np

# Every spectrum in the bake lives on this grid. Profiles bring their own wavelengths
# and are resampled onto it.
WAVELENGTHS = np.arange(380.0, 781.0, 5.0)

REC2020_PRIMARIES = ((0.708, 0.292), (0.170, 0.797), (0.131, 0.046))
D65_XY = (0.3127, 0.3290)

CMF_TABLE = "cie_1931_2deg_cmf_380-780_5nm.csv"
DAYLIGHT_TABLE = "cie_daylight_components_S0S1S2_300-830_5nm.csv"

_BRADFORD = np.array([[0.8951, 0.2664, -0.1614],
                      [-0.7502, 1.7135, 0.0367],
                      [0.0389, -0.0685, 1.0296]])


def load_data_text(name: str) -> str:
    """The text of a file in the package's `data/` folder."""
    return resources.files(__package__).joinpath("data", name).read_text(encoding="utf-8")


def load_data_table(name: str) -> np.ndarray:
    """A comma-separated table from `data/`, comment and header lines skipped, blanks as NaN."""
    rows = []
    for line in load_data_text(name).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            rows.append([float(v) if v.strip() else float("nan") for v in line.split(",")])
        except ValueError:
            continue  # the column header line
    return np.asarray(rows, dtype=float)


@lru_cache(maxsize=None)
def _cmf_table():
    table = load_data_table(CMF_TABLE)
    return table[:, 0], table[:, 1:4]


@lru_cache(maxsize=None)
def _daylight_components():
    table = load_data_table(DAYLIGHT_TABLE)
    return table[:, 0], table[:, 1], table[:, 2], table[:, 3]


def cie_1931(wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """CIE 1931 2 degree colour-matching functions on `wl`, as an (n, 3) array of x-bar, y-bar, z-bar.

    Linearly resampled from the tabulated 5 nm values, zero outside 380 to 780 nm. On the
    bake grid the resampling is the identity.
    """
    table_wl, table = _cmf_table()
    wl = np.asarray(wl, dtype=float)
    return np.stack([np.interp(wl, table_wl, table[:, k], left=0.0, right=0.0) for k in range(3)], axis=1)


def daylight(cct: float, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """CIE daylight illuminant of correlated colour temperature `cct` kelvin, 100 at 560 nm.

    CIE 15:2004 section 3.1: the chromaticity x_D from the polynomial for 4000 to 7000 K or
    for 7000 to 25000 K, y_D = -3.000 x_D^2 + 2.870 x_D - 0.275, the weights M1 and M2
    rounded to three decimals as the standard asks, S = S0 + M1 S1 + M2 S2 from the
    tabulated components, normalized to 100 at 560 nm and linearly resampled onto `wl`.
    D50, D55 and D65 are 5003, 5503 and 6504 K.
    """
    if not 4000.0 <= cct <= 25000.0:
        raise ValueError(f"CIE daylight is defined for 4000 to 25000 K, not {cct}")
    t = float(cct)
    if t <= 7000.0:
        x = -4.6070e9 / t ** 3 + 2.9678e6 / t ** 2 + 0.09911e3 / t + 0.244063
    else:
        x = -2.0064e9 / t ** 3 + 1.9018e6 / t ** 2 + 0.24748e3 / t + 0.237040
    y = -3.000 * x ** 2 + 2.870 * x - 0.275
    denominator = 0.0241 + 0.2562 * x - 0.7341 * y
    m1 = round((-1.3515 - 1.7703 * x + 5.9114 * y) / denominator, 3)
    m2 = round((0.0300 - 31.4424 * x + 30.0717 * y) / denominator, 3)
    table_wl, s0, s1, s2 = _daylight_components()
    spectrum = s0 + m1 * s1 + m2 * s2
    spectrum = 100.0 * spectrum / np.interp(560.0, table_wl, spectrum)
    return np.interp(np.asarray(wl, dtype=float), table_wl, spectrum)


def blackbody(temperature: float, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """Relative spectral power of a blackbody, scaled to 1 at 560 nm."""
    c2 = 1.4388e-2  # second radiation constant, m K

    def power(nm):
        m = nm * 1e-9
        return m ** -5 / np.expm1(c2 / (m * temperature))

    return power(wl) / power(560.0)


D50 = daylight(5003.0)
D55 = daylight(5503.0)
D65 = daylight(6504.0)


def gaussian(center: float, width: float, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """A unit-peak Gaussian bump, for synthetic spectra."""
    return np.exp(-0.5 * ((wl - center) / width) ** 2)


def resample(source_wl, values, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """Linear resample onto the bake grid. Zero outside the measured range."""
    return np.interp(wl, source_wl, values, left=0.0, right=0.0)


def resample_hold(source_wl, values, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """Linear resample onto the bake grid, holding the end values outside the measured range.

    For density spectra: a base or a dye does not become transparent where the sheet's
    plot stops.
    """
    return np.interp(wl, source_wl, values)


def resample_log(source_wl, log_values, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """Resample a log10 curve, such as a datasheet's log sensitivity, and return it linear.

    Interpolation happens in the log domain, where the datasheet drew the curve. Outside
    the measured range the film does not respond at all, and a sample that is not finite
    (a null in the profile) means the same: no response there, and no interpolation across it.
    """
    source_wl = np.asarray(source_wl, dtype=float)
    log_values = np.asarray(log_values, dtype=float)
    missing = ~np.isfinite(log_values)
    linear = 10.0 ** np.interp(wl, source_wl, np.where(missing, 0.0, log_values))
    outside = (wl < source_wl[0]) | (wl > source_wl[-1]) | (np.interp(wl, source_wl, missing.astype(float)) > 0.0)
    linear[outside] = 0.0
    return linear


def xy_to_xyz(x: float, y: float) -> np.ndarray:
    """Chromaticity to XYZ with Y = 1."""
    return np.array([x / y, 1.0, (1.0 - x - y) / y])


def white_point(illuminant: np.ndarray, wl: np.ndarray = WAVELENGTHS) -> np.ndarray:
    """XYZ of an illuminant, scaled to Y = 1."""
    xyz = illuminant @ cie_1931(wl)
    return xyz / xyz[1]


def rgb_to_xyz_matrix(primaries=REC2020_PRIMARIES, white_xyz: np.ndarray | None = None) -> np.ndarray:
    """The matrix taking linear RGB to XYZ, scaled so equal RGB is `white_xyz` (default D65)."""
    white = xy_to_xyz(*D65_XY) if white_xyz is None else white_xyz
    columns = np.stack([xy_to_xyz(*p) for p in primaries], axis=1)
    return columns * np.linalg.solve(columns, white)


def adaptation_matrix(source_white: np.ndarray, destination_white: np.ndarray) -> np.ndarray:
    """Bradford chromatic adaptation between two XYZ white points."""
    source = _BRADFORD @ source_white
    destination = _BRADFORD @ destination_white
    return np.linalg.inv(_BRADFORD) @ np.diag(destination / source) @ _BRADFORD
