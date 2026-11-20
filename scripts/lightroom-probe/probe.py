"""Shared reading and analysis for the Lightroom slider probe (docs/research/lightroom-sliders.md).

Everything here is the measurement, not the renderer: reading Lightroom's and Argent's TIFFs,
CIE L*, the tone base field (the same math as `ToneBaseField`, references/lightroom-probe/DESIGN.md),
a monotone fit of a render's transfer from scene stops to output L*, the gain-on-base fit of a
local control, and running argent-spike. numpy only.
"""
import os
import struct
import subprocess
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "references" / "lightroom-probe"
CONTROLS = ["contrast", "highlights", "shadows", "whites", "blacks"]
GLOBAL = ["contrast", "whites", "blacks"]
LOCAL = ["highlights", "shadows"]
VALUES = [-100, -50, -25, 25, 50, 100]
EXPOSURES = [-2.0, -1.0, -0.5, 0.5, 1.0, 2.0]
# Luminance of linear ProPhoto RGB (D50, as Lightroom exports it) and of linear sRGB.
PROPHOTO_Y = np.array([0.2880402, 0.7118741, 0.0000857])
SRGB_Y = np.array([0.2126, 0.7152, 0.0722])
# The analysis works on 4 x 4 blocks averaged in linear light: 1752 x 1168 for a 7008 x 4672 frame.
BLOCK = 4
# The output L* grid of the generated targets.
LIGHTNESS = np.round(np.arange(0, 100.001, 2.5), 2)


def variant_name(control, value):
    """The probe's file stem for a control at a value: raw_NN_<control>_<value>."""
    return f"{control}_{value:+.2f}" if control == "exposure" else f"{control}_{value:+d}"


def variants():
    """(control, value) for every probe variant, the base first as (None, 0)."""
    out = [(None, 0)] + [("exposure", e) for e in EXPOSURES]
    out += [(c, v) for c in CONTROLS for v in VALUES]
    return out


# MARK: Reading

TYPES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 16: 8}


def read_tiff(path):
    """An uncompressed 8- or 16-bit TIFF's first three channels in 0...1, and its ICC profile."""
    b = Path(path).read_bytes()
    e = "<" if b[:2] == b"II" else ">"
    off = struct.unpack(e + "I", b[4:8])[0]
    n = struct.unpack(e + "H", b[off:off + 2])[0]
    tags = {}
    for i in range(n):
        t, ty, c, v = struct.unpack(e + "HHI4s", b[off + 2 + 12 * i:off + 14 + 12 * i])
        size = TYPES.get(ty, 1) * c
        at = struct.unpack(e + "I", v)[0]
        data = v if size <= 4 else b[at:at + size]
        if ty == 3:
            tags[t] = struct.unpack(e + f"{c}H", data[:2 * c])
        elif ty == 4:
            tags[t] = struct.unpack(e + f"{c}I", data[:4 * c])
        else:
            tags[t] = data[:size]
    w, h = tags[256][0], tags[257][0]
    if tags.get(259, (1,))[0] != 1:
        raise SystemExit(f"{path}: compressed TIFF; export uncompressed")
    spp, bps = tags[277][0], tags[258][0]
    raw = b"".join(b[o:o + c] for o, c in zip(tags[273], tags[279]))
    dt = np.dtype(e + ("u2" if bps == 16 else "u1"))
    img = np.frombuffer(raw, dt).reshape(h, w, spp)[:, :, :3]
    return img.astype(np.float32) / (65535 if bps == 16 else 255), tags.get(34675)


def icc_gamma(icc):
    """The pure gamma of an ICC profile's rTRC, or None when it is a table or parametric curve."""
    count = struct.unpack(">I", icc[128:132])[0]
    for i in range(count):
        sig, o, s = struct.unpack(">4sII", icc[132 + 12 * i:144 + 12 * i])
        if sig == b"rTRC" and icc[o:o + 4] == b"curv" and struct.unpack(">I", icc[o + 8:o + 12])[0] == 1:
            return struct.unpack(">H", icc[o + 12:o + 14])[0] / 256
    return None


def lightroom_luminance(path):
    """Linear luminance of a Lightroom export: 16-bit ProPhoto RGB with its pure-gamma rTRC (461/256)."""
    img, icc = read_tiff(path)
    gamma = icc_gamma(icc) if icc else None
    if gamma is None:
        raise SystemExit(f"{path}: expected ProPhoto RGB with a pure-gamma profile")
    return np.power(img, gamma) @ PROPHOTO_Y.astype(np.float32)


def srgb_luminance(path):
    """Linear luminance of argent-spike's `--tiff` output, 16-bit sRGB."""
    img, _ = read_tiff(path)
    lin = np.where(img <= 0.04045, img / 12.92, np.power((img + 0.055) / 1.055, 2.4))
    return lin @ SRGB_Y.astype(np.float32)


def block_mean(a, k=BLOCK):
    h, w = a.shape[0] // k * k, a.shape[1] // k * k
    return a[:h, :w].reshape(h // k, k, w // k, k).mean(axis=(1, 3))


def lstar(Y):
    """CIE L* of relative luminance, white Y = 1 at L* 100."""
    Y = np.maximum(Y, 0)
    return 116 * np.where(Y > (6 / 29) ** 3, np.cbrt(Y), Y / (3 * (6 / 29) ** 2) + 4 / 29) - 16


def luminance(L):
    """Relative luminance of CIE L*, the inverse of `lstar`."""
    f = (np.asarray(L, dtype=np.float64) + 16) / 116
    return np.where(f > 6 / 29, f ** 3, 3 * (6 / 29) ** 2 * (f - 4 / 29))


def cached(path, make):
    """`make()` saved beside the data as .npy, remade when `path` is newer than the cache."""
    cache = DATA / "cache" / f"{Path(path).parent.name}-{Path(path).stem}.b{BLOCK}.npy"
    if cache.exists() and cache.stat().st_mtime >= Path(path).stat().st_mtime:
        return np.load(cache)
    cache.parent.mkdir(parents=True, exist_ok=True)
    value = make()
    np.save(cache, value)
    return value


def lightroom_lstar(path):
    """A Lightroom export's L* at the analysis resolution."""
    return lstar(cached(path, lambda: block_mean(lightroom_luminance(path))).astype(np.float64))


# MARK: The tone base field (DESIGN.md, ToneBaseField)

# The gain-table compilers' constants, as ToneBaseParameters.compiler2026_10_29_1 (2026-11-06-1 reads
# the same field, before Exposure where 2026-10-29-1 reads it after): the box radius as a
# share of the field's long side, epsilon in stops squared, the field's long side, and the
# coefficient boxes' radius as a share of the guide boxes'.
RADIUS_FRACTION = 0.015
EPSILON = 0.7
FIELD_LONG_SIDE = 1024
COEFFICIENT_SHARE = 0.5


def rounded(x):
    """Swift's `rounded()`: to the nearest whole number, halves away from zero (x >= 0 here)."""
    return int(np.floor(x + 0.5))


def area_matrix(n_in, n_out):
    """Exact area averaging of `n_in` cells into `n_out`, as a matrix."""
    m = np.zeros((n_out, n_in))
    edges = np.arange(n_out + 1) * n_in / n_out
    for o in range(n_out):
        a, b = edges[o], edges[o + 1]
        for i in range(int(np.floor(a)), min(int(np.ceil(b)), n_in)):
            m[o, i] = min(b, i + 1) - max(a, i)
        m[o] /= m[o].sum()
    return m


def box(x, r):
    """Mean over a (2r+1)^2 box with clamped edges."""
    for axis in (0, 1):
        n = x.shape[axis]
        p = np.take(x, np.clip(np.arange(-r, n + r), 0, n - 1), axis=axis)
        c = np.cumsum(p, axis=axis, dtype=np.float64)
        c = np.concatenate([np.zeros_like(np.take(c, [0], axis=axis)), c], axis=axis)
        x = (np.take(c, np.arange(2 * r + 1, n + 2 * r + 1), axis=axis) - np.take(c, np.arange(n), axis=axis)) / (2 * r + 1)
    return x


class ToneBase:
    """The guided-filter base of log2 luminance, as `ToneBaseField` makes it: the frame's linear
    luminance before Exposure area-averaged into a field `long_side` pixels long, in linear light,
    then its guide g = log2(sqrt(Y^2 + 1e-12)); the filter's coefficients there, and base =
    a(uv) g + b(uv) at any resolution, g the pixel's own guide and (a, b) bilinear."""

    def __init__(self, Y_full, long_side=FIELD_LONG_SIDE):
        h, w = Y_full.shape
        self.F = min(long_side, max(h, w))
        fw, fh = (self.F, rounded(h * self.F / w)) if w >= h else (rounded(w * self.F / h), self.F)
        Y = area_matrix(h, fh) @ Y_full.astype(np.float64) @ area_matrix(w, fw).T
        self.g = np.clip(np.log2(np.sqrt(Y ** 2 + 1e-12)), -40, 40)

    def coefficients(self, radius_fraction, epsilon, coefficient_share=COEFFICIENT_SHARE):
        r = max(1, rounded(radius_fraction * self.F))
        mu = box(self.g, r)
        var = np.maximum(box(self.g * self.g, r) - mu * mu, 0)
        a = var / (var + epsilon)
        rc = max(1, rounded(r * coefficient_share))
        return box(a, rc), box(mu - a * mu, rc)

    @staticmethod
    def sample(c, shape):
        """Bilinear at uv = (p + 0.5) / size, clamped to the edge texels."""
        fh, fw = c.shape

        def coords(n, fn):
            t = np.clip((np.arange(n) + 0.5) / n * fn - 0.5, 0, fn - 1)
            i = np.minimum(np.floor(t).astype(int), fn - 2)
            return i, t - i

        y0, fy = coords(shape[0], fh)
        x0, fx = coords(shape[1], fw)
        top = c[y0][:, x0] * (1 - fx) + c[y0][:, x0 + 1] * fx
        bottom = c[y0 + 1][:, x0] * (1 - fx) + c[y0 + 1][:, x0 + 1] * fx
        return top * (1 - fy)[:, None] + bottom * fy[:, None]

    def base(self, g, radius_fraction, epsilon, coefficient_share=COEFFICIENT_SHARE):
        """The base log2 luminance for guide values `g` laid out over the whole frame."""
        a, b = self.coefficients(radius_fraction, epsilon, coefficient_share)
        return self.sample(a, g.shape) * g + self.sample(b, g.shape)


# MARK: Curves

def pava(y, w):
    """Weighted isotonic (non-decreasing) regression."""
    blocks = []
    for v, wt in zip(y, w):
        blocks.append([v * wt, wt, 1])
        while len(blocks) > 1 and blocks[-2][0] / blocks[-2][1] > blocks[-1][0] / blocks[-1][1]:
            s, ww, n = blocks.pop()
            blocks[-1][0] += s
            blocks[-1][1] += ww
            blocks[-1][2] += n
    return np.concatenate([[s / ww] * n for s, ww, n in blocks])


def whittaker(y, w, lam):
    """Smooth `y` with weights `w` under a second-difference penalty `lam`."""
    n = len(y)
    d = np.diff(np.eye(n), 2, axis=0)
    return np.linalg.solve(np.diag(w) + lam * d.T @ d, w * y)


def binned_median(x, y, edges, minimum=50):
    """Centres, medians and counts of `y` in bins of `x`, bins with fewer than `minimum` dropped."""
    j = np.digitize(x, edges) - 1
    ok = (j >= 0) & (j < len(edges) - 1)
    j, y = j[ok], y[ok]
    order = np.argsort(j, kind="stable")
    j, y = j[order], y[order]
    starts = np.searchsorted(j, np.arange(len(edges)))
    centres, medians, counts = [], [], []
    for i in range(len(edges) - 1):
        part = y[starts[i]:starts[i + 1]]
        if len(part) >= minimum:
            centres.append(0.5 * (edges[i] + edges[i + 1]))
            medians.append(np.median(part))
            counts.append(len(part))
    return np.array(centres), np.array(medians), np.array(counts)


class Transfer:
    """A render's transfer from scene stops (log2 of the guide's luminance) to output L*: binned
    medians, made non-decreasing and smoothed, on a fine grid; outside the data it approaches
    L* 0 and 100 smoothly. With its derivative, for the gain fit."""

    STEP = 0.02

    def __init__(self, x, L, low=-8.0, high=7.0):
        c, m, n = binned_median(x, L, np.arange(low, high + 1e-9, 0.1), minimum=40)
        m = pava(m, np.minimum(n, 2000))
        m = whittaker(m, np.minimum(n, 2000).astype(float), 30.0)
        m = pava(m, np.ones_like(m))
        self.grid = np.arange(-16, 12 + 1e-9, self.STEP)
        T = np.interp(self.grid, c, m)
        below, above = self.grid < c[0], self.grid > c[-1]
        # Below the data luminance halves per stop; above it the distance to white halves.
        T[below] = lstar(luminance(m[0]) * 2.0 ** (self.grid[below] - c[0]))
        T[above] = 100 - (100 - m[-1]) * 2.0 ** (-(self.grid[above] - c[-1]))
        self.T = T
        self.dT = np.gradient(T, self.STEP)
        self.data_range = (c[0], c[-1])

    def __call__(self, x):
        return np.interp(x, self.grid, self.T)

    def slope(self, x):
        return np.interp(x, self.grid, self.dT)

    def inverse(self, L):
        T = np.maximum.accumulate(self.T + np.arange(len(self.T)) * 1e-9)
        return np.interp(L, T, self.grid)


def fit_gain(transfer, x, xb, dL, knots, lam=0.03, iterations=8):
    """The gain in stops, piecewise linear in the base `xb` over `knots`, that best explains each
    pixel's output change `dL` as transfer(x + gain(xb)) - transfer(x). Returns the knot gains,
    held constant outside the knots, and the predicted change."""
    k = len(knots)
    step = knots[1] - knots[0]
    t = np.clip((xb - knots[0]) / step, 0, k - 1 - 1e-9)
    i = np.floor(t).astype(int)
    f = t - i
    gk = np.zeros(k)
    d2 = np.diff(np.eye(k), 2, axis=0)
    penalty = lam * len(dL) / k * d2.T @ d2 + 1e-6 * len(dL) / k * np.eye(k)
    for _ in range(iterations):
        g = gk[i] * (1 - f) + gk[i + 1] * f
        r = dL - (transfer(x + g) - transfer(x))
        s = transfer.slope(x + g)
        j0, j1 = s * (1 - f), s * f
        jtj = np.diag(np.bincount(i, j0 * j0, k) + np.bincount(i + 1, j1 * j1, k))
        off = np.bincount(i, j0 * j1, k)[:-1]
        jtj += np.diag(off, 1) + np.diag(off, -1)
        jtr = np.bincount(i, j0 * r, k) + np.bincount(i + 1, j1 * r, k)
        gk = gk + np.linalg.solve(jtj + penalty, jtr - penalty @ gk)
    g = gk[i] * (1 - f) + gk[i + 1] * f
    return gk, transfer(x + g) - transfer(x)


def r_squared(observed, predicted):
    return 1 - np.var(observed - predicted) / np.var(observed)


# MARK: argent-spike

def spike(raw, out, stock, *flags, binary=None, env=None):
    """Runs argent-spike on `raw` into `out`, returning its output; raises on failure."""
    binary = binary or ROOT / ".build" / "release" / "argent-spike"
    cmd = [str(binary), str(raw), "--stock", str(stock), "--out", str(out), "--no-warmup", *map(str, flags)]
    run = subprocess.run(cmd, capture_output=True, text=True, env=env or os.environ.copy())
    if run.returncode != 0:
        raise SystemExit(f"argent-spike failed ({' '.join(cmd)}):\n{run.stdout}\n{run.stderr}")
    return run.stdout


def guide(raw, stock, binary=None):
    """The probe raw's linear luminance before Exposure at full size, as the base field's guide;
    decoded without lens corrections, so it lies pixel for pixel on Lightroom's export
    (registration residual 0.006 px over a 7 x 9 grid of tiles; with them it is off by up to 2 px)."""
    out = DATA / "cache" / "guide"
    path = out / (Path(raw).stem + ".luminance.npy")
    if not path.exists() or path.stat().st_mtime < Path(raw).stat().st_mtime:
        spike(raw, out, stock, "--tiff", "--no-lens", "--save-luminance", "--long-edge", 64, binary=binary)
    return np.load(path)
