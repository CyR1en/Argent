"""Halation from first principles: how much light the base returns, and how far it spreads.

Light scattered at the bottom of the emulsion goes down through the antihalation undercoat
(normal density D per pass), crosses the base (thickness t, index n_b, an optional dye density
Db through its thickness), reflects at the base's back surface and comes back. Below the critical
angle the back surface returns the Fresnel share; above it, where n_g sin(theta_g) > 1 in the
gelatin, it reflects totally, so the halo is a ring that starts at r = 2 t tan(asin(1 / n_b)).
The scattering into the gelatin is taken as Lambertian, which gives the most light past the
critical angle and so the widest, strongest halo this geometry allows; forward-peaked scattering
gives a tighter, weaker one. The undercoat is crossed at the gelatin's angle and the base at its
own, each path 1 / cos(theta) longer than the normal.

The base, 0.10 mm ESTAR, is printed on the Portra, Ektar and Gold sheets (verified). Kodak's
TI-2598 gives ESTAR's index as 1.64 and 1.66 in the plane and 1.50 through the thickness, and
Kodak's US2481770 gives emulsions "about 1.54" (both reported by the research agent from the
primary sources); 1.65 is the default here and 1.50 the other polarisation's bound, which moves
the ring out by about a sixth. No sheet publishes its undercoat's density. Kodak's colour negative
patents of 1993 to 2002 coat it with 0.107 to 0.236 g/m2 of grey or black colloidal silver
(typically 0.151), and such silver reads 1.2 to 2.1 density per g/m2, so 0.13 to 0.49 per pass
(reported, inference; docs/research/film.md section 4.4), which bounds what a stock's halation
strength can be. `tools/halation_geometry.py` prints the
tables; the render's kernel (`HalationField.mixture` in the app) is weighted to this geometry.
"""

import numpy as np

BASE_UM = 100.0
GELATIN = 1.54
RADIUS_UM = 180.0  # the profiles' radiusMicrometres, the kernel's scale a
SCALES = np.array([0.5, 1.0, 2.0, 4.0, 8.0, 16.0])  # HalationField.mixture's sigmas, in units of a
HEAVY_TAILED = np.array([0.1479, 0.3522, 0.2423, 0.1443, 0.0603, 0.0530])  # its weights until 2026-10-07
# The undercoat at which the geometry returns about 2.5 percent, so that a red layer absorbing half
# to all of what reaches it again gives the profiles' strength of 1.5 percent (inference). The
# weights fitted there with gelatin at 1.52, 0.293 and 0.707, rounded, are HalationField.mixture
# since 2026-10-07; with gelatin at 1.54 the fit is 0.26 and 0.74, which moves the halo's median
# by 6 micrometres, so the weights were not refitted.
REFERENCE_UNDERCOAT = 0.4
MIXTURE = np.array([0.30, 0.70, 0.0, 0.0, 0.0, 0.0])
# The undercoat's density per pass from Kodak's patents' silver coverages (reported, inference).
UNDERCOAT_RANGE = (0.13, 0.49)


def fresnel(n1: float, n2: float, cos_i: np.ndarray) -> np.ndarray:
    """Unpolarized reflectance from n1 into n2; 1 past the critical angle."""
    sin_t = n1 / n2 * np.sqrt(np.maximum(0.0, 1.0 - cos_i ** 2))
    cos_t = np.sqrt(np.maximum(0.0, 1.0 - sin_t ** 2))
    rs = ((n1 * cos_i - n2 * cos_t) / (n1 * cos_i + n2 * cos_t)) ** 2
    rp = ((n1 * cos_t - n2 * cos_i) / (n1 * cos_t + n2 * cos_i)) ** 2
    return np.where(sin_t >= 1.0, 1.0, 0.5 * (rs + rp))


def returned(undercoat: float, base_dye: float = 0.0, base_index: float = 1.65, samples: int = 200_000):
    """(radius in micrometres, share of the downward light returned there) over the gelatin's angles."""
    theta = (np.arange(samples) + 0.5) / samples * (np.pi / 2)
    flux = np.sin(2 * theta) * (np.pi / 2) / samples  # Lambertian: 2 sin cos d(theta), sums to 1
    sin_b = GELATIN * np.sin(theta) / base_index
    cos_b = np.sqrt(1.0 - sin_b ** 2)
    transmitted = 10.0 ** (-2 * undercoat / np.cos(theta)) * 10.0 ** (-2 * base_dye / cos_b)
    radius = 2 * BASE_UM * sin_b / cos_b
    return radius, flux * fresnel(base_index, 1.0, cos_b) * transmitted


def cdf_on(grid: np.ndarray, radius: np.ndarray, energy: np.ndarray) -> np.ndarray:
    order = np.argsort(radius)
    return np.interp(grid, radius[order], np.cumsum(energy[order]) / energy.sum())


def mixture_cdf(grid: np.ndarray, weights: np.ndarray, a: float = RADIUS_UM) -> np.ndarray:
    """Energy inside each radius for the Gaussian mixture: 1 - exp(-r^2 / 2 sigma^2) per Gaussian."""
    return (weights[None, :] * (1 - np.exp(-grid[:, None] ** 2 / (2 * (SCALES * a) ** 2)))).sum(axis=1)


def quantiles(grid: np.ndarray, cdf: np.ndarray) -> tuple:
    return tuple(float(grid[min(np.searchsorted(cdf, q), grid.size - 1)]) for q in (0.1, 0.5, 0.9))


def strength_bounds(base_dye: float = 0.0) -> tuple:
    """The halation strength the geometry allows over the undercoat range.

    The strength is the halo's energy over the light the red layer took directly. The light that
    passes the layer is at most all of it and the layer re-absorbs the return at most as it did
    the first time, so the strength is at most what the base returns at the thinnest undercoat;
    at least a quarter of it (half the light passing, half re-absorbed, inference) at the densest.
    """
    low = 0.25 * float(returned(UNDERCOAT_RANGE[1], base_dye)[1].sum())
    high = float(returned(UNDERCOAT_RANGE[0], base_dye)[1].sum())
    return low, high
