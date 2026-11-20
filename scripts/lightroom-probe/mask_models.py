"""Numerics shared by the mask analysis (analyze_masks.py) and the synthetic exports that test it (synth_masks.py).

numpy only. Three things live here:

* the candidate laws the session decides between: the profile of an edge (smoothstep, linear, ...), the algebra
  of components (R8's probabilistic one, min/max, Lukasiewicz), and how a coverage scales an adjustment;
* Argent's candidate arithmetic, R5's, written the way R5's `SceneCPU.gains` writes it, but driven by tables
  built from Lightroom's own whole-frame renders (`RampTables`), so that what is tested is the composition
  law and not the film's transfer;
* small tools: a monotone cubic interpolation (`pchip`), the inversion of Exposure's response
  (`ExposureResponse`), and the geometry of Lightroom's two gradients as this project reads it.

R5's arithmetic, in stops (docs/masking-plan.md section 4), for a pixel with level x (log2 luminance), local
base xb, coverage c_k of mask k, layer 0 the global panel with c = 1:

    e  = sum_k c_k E_k                     u = x + e         ub = xb + e
    t  = sum_k c_k L_k(ub)                 every local gain (Highlights, then Shadows) at the base: they add
    t += c_k G_k(u + t), k in list order   every layer's global gain (Whites, Blacks, then Contrast), at the level so far
    level after = u + t
"""
import numpy as np

import probe

LSTAR = probe.lstar
LUMINANCE = probe.luminance


# MARK: Interpolation

def _pchip_slopes(x, y):
    h = np.diff(x)
    shape = (-1,) + (1,) * (y.ndim - 1)
    d = np.diff(y, axis=0) / h.reshape(shape)
    n = len(x)
    m = np.zeros_like(y)
    if n == 2:
        m[:] = d[0]
        return m
    for i in range(1, n - 1):
        d0, d1 = d[i - 1], d[i]
        w1, w2 = 2 * h[i] + h[i - 1], h[i] + 2 * h[i - 1]
        same = d0 * d1 > 0
        m[i] = np.where(same, (w1 + w2) / (w1 / np.where(d0 == 0, 1, d0) + w2 / np.where(d1 == 0, 1, d1)), 0)

    def end(h0, h1, d0, d1):
        e = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
        e = np.where(np.sign(e) != np.sign(d0), 0, e)
        return np.where((np.sign(d0) != np.sign(d1)) & (np.abs(e) > 3 * np.abs(d0)), 3 * d0, e)

    m[0] = end(h[0], h[1], d[0], d[1])
    m[-1] = end(h[-1], h[-2], d[-1], d[-2])
    return m


def pchip(x, y, xq):
    """Monotone cubic Hermite interpolation (Fritsch-Carlson) of y (n, ...) over increasing x (n,), at xq (m,) -> (m, ...).
    Outside [x[0], x[-1]] the end values are held."""
    x, y = np.asarray(x, float), np.asarray(y, float)
    xq = np.clip(np.asarray(xq, float), x[0], x[-1])
    m = _pchip_slopes(x, y)
    i = np.clip(np.searchsorted(x, xq, side="right") - 1, 0, len(x) - 2)
    h = (x[i + 1] - x[i])
    t = (xq - x[i]) / h
    shape = (-1,) + (1,) * (y.ndim - 1)
    t, h = t.reshape(shape), h.reshape(shape)
    t2, t3 = t * t, t * t * t
    return ((2 * t3 - 3 * t2 + 1) * y[i] + (t3 - 2 * t2 + t) * h * m[i]
            + (-2 * t3 + 3 * t2) * y[i + 1] + (t3 - t2) * h * m[i + 1])


class ExposureResponse:
    """A chart's global Exposure series: output L* against exposure, one curve per column. `exposure_of(obs)` is the exposure
    that gives an observed L* (NaN outside the series, or where the response is flat)."""

    def __init__(self, exposures, series, step=0.004, min_slope=0.7):
        e = np.asarray(exposures, float)
        order = np.argsort(e)
        self.series_e = e[order]
        S = np.asarray(series, float)[order]
        if S.ndim == 1:
            S = S[:, None]
        self.e = np.arange(self.series_e[0], self.series_e[-1] + step / 2, step)
        self.L = np.maximum.accumulate(pchip(self.series_e, S, self.e), axis=0)
        self.slope = np.gradient(self.L, self.e, axis=0)
        self.min_slope = min_slope

    @property
    def columns(self):
        return self.L.shape[1]

    def L_at(self, e):
        """L* at exposure(s) e, per column: shape (len(e), columns)."""
        e = np.atleast_1d(np.asarray(e, float))
        idx = np.clip(np.searchsorted(self.e, e), 0, len(self.e) - 1)
        return self.L[idx]

    def exposure_of(self, obs):
        obs = np.asarray(obs, float)
        if obs.ndim == 1:
            obs = obs[:, None]
        out = np.full(obs.shape, np.nan)
        ramp = np.arange(self.L.shape[0]) * 1e-9
        for j in range(obs.shape[1]):
            col = self.L[:, min(j, self.columns - 1)]
            x = obs[:, j]
            ok = (x >= col[0]) & (x <= col[-1])
            e = np.interp(x[ok], col + ramp, self.e)
            s = np.interp(e, self.e, self.slope[:, min(j, self.columns - 1)])
            e[s < self.min_slope] = np.nan
            out[ok, j] = e
        return out


# MARK: Candidate laws

def smoothstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def smootherstep(t):
    t = np.clip(t, 0.0, 1.0)
    return t * t * t * (t * (6 * t - 15) + 10)


def linearstep(t):
    return np.clip(t, 0.0, 1.0)


def cosinestep(t):
    return 0.5 - 0.5 * np.cos(np.pi * np.clip(t, 0.0, 1.0))


# S(t): rises from 0 to 1 over t in [0, 1]. An edge is 1 - S((position - a) / (b - a)).
PROFILES = {"smoothstep": smoothstep, "linear": linearstep, "smootherstep": smootherstep, "cosine": cosinestep}

# Three self-consistent algebras of components. Intersect is Subtract of the inverted component (KOST24, MCP-325),
# so each satisfies intersect(c, v) = subtract(c, 1 - v).
ALGEBRAS = {
    "prob": {"add": lambda c, v: c + v - c * v, "sub": lambda c, v: c * (1 - v), "int": lambda c, v: c * v},
    "minmax": {"add": np.maximum, "sub": lambda c, v: np.minimum(c, 1 - v), "int": np.minimum},
    "luk": {"add": lambda c, v: np.minimum(1, c + v), "sub": lambda c, v: np.maximum(0, c - v),
            "int": lambda c, v: np.maximum(0, c + v - 1)},
}


def fit_edge(position, alpha, families=PROFILES, lo=None, hi=None, grid=41):
    """The best (family, a, b) for alpha(position) = 1 - S((position - a) / (b - a)): least squares over a and b on a grid
    inside [lo, hi] (default the data's range), then refined around the best cell. Returns a list of dicts, best first."""
    position, alpha = np.asarray(position, float), np.asarray(alpha, float)
    ok = np.isfinite(position) & np.isfinite(alpha)
    position, alpha = position[ok], alpha[ok]
    lo = position.min() if lo is None else lo
    hi = position.max() if hi is None else hi
    results = []
    for name, S in families.items():
        best = (np.inf, None, None)
        a_grid = np.linspace(lo, hi, grid)
        b_grid = np.linspace(lo, hi, grid)
        for _ in range(3):
            for a in a_grid:
                for b in b_grid:
                    if b - a < 1e-3:
                        continue
                    err = np.mean((1 - S((position - a) / (b - a)) - alpha) ** 2)
                    if err < best[0]:
                        best = (err, a, b)
            sa = (a_grid[1] - a_grid[0])
            sb = (b_grid[1] - b_grid[0])
            a_grid = np.linspace(best[1] - sa, best[1] + sa, grid)
            b_grid = np.linspace(best[2] - sb, best[2] + sb, grid)
        results.append({"family": name, "a": float(best[1]), "b": float(best[2]), "rms": float(np.sqrt(best[0]))})
    return sorted(results, key=lambda r: r["rms"])


# MARK: Geometry (as this project reads Lightroom's two gradients)

def pixel_grid(h, w):
    """Normalized coordinates (u, v) of the centres of an h x w grid, origin top left, v down."""
    return (np.arange(w) + 0.5) / w, (np.arange(h) + 0.5) / h


def gradient_t(h, w, full, zero, pixel_space=True):
    """Position along a linear gradient: 0 at the Full point, 1 at the Zero point, a field (h, w). With pixel_space the
    distances are measured in pixels (the isolines are perpendicular to the line on the picture); otherwise in the
    normalized coordinates (perpendicular on the unit square, skewed on a wide picture)."""
    u, v = pixel_grid(h, w)
    sx, sy = (w, h) if pixel_space else (1.0, 1.0)
    X, Y = np.meshgrid(u * sx, v * sy)
    fx, fy, zx, zy = full[0] * sx, full[1] * sy, zero[0] * sx, zero[1] * sy
    dx, dy = zx - fx, zy - fy
    return ((X - fx) * dx + (Y - fy) * dy) / (dx * dx + dy * dy)


def radial_n(h, w, left, top, right, bottom, angle=0.0):
    """Normalized elliptical radius of a radial gradient's box: 0 at its centre, 1 on its outline, a field (h, w). The box
    is in normalized coordinates; the ellipse is measured in pixels and turned by `angle` degrees (clockwise on the
    picture for a positive angle; the analysis tries both signs)."""
    u, v = pixel_grid(h, w)
    X, Y = np.meshgrid(u * w, v * h)
    cx, cy = (left + right) / 2 * w, (top + bottom) / 2 * h
    rx, ry = abs(right - left) / 2 * w, abs(bottom - top) / 2 * h
    a = np.deg2rad(angle)
    dx, dy = X - cx, Y - cy
    px = np.cos(a) * dx + np.sin(a) * dy
    py = -np.sin(a) * dx + np.cos(a) * dy
    return np.sqrt((px / rx) ** 2 + (py / ry) ** 2), (rx, ry)


# MARK: R5's arithmetic over tables built from Lightroom's own renders

LOCAL_ORDER = ["H", "S"]
GLOBAL_ORDER = ["W", "B", "C"]


class RampTables:
    """From the ramp chart's whole-frame renders: the base transfer T (level in stops under white -> output L*), and each
    control's gain table g(level; value) in stops, g = T^-1(L*_value(level)) - level, for any value between the measured
    ones (the render at a value in between is interpolated in the slider value: the slider-scaling reading).

    `x` are the columns' levels (increasing), `base` their L* in the base render, `globals_` maps (control, value) to the
    L* of that render's columns. `transfer` = (levels, L*) is T on a wider range than the columns', when the Exposure series
    gives it (a column at level x under Exposure e shows T(x + e)); without it T is the base render's columns."""

    def __init__(self, x, base, globals_, transfer=None):
        self.x = np.asarray(x, float)
        self.T_cols = np.maximum.accumulate(np.asarray(base, float))
        if transfer is None:
            self.T_levels, self.T_vals = self.x, self.T_cols
        else:
            self.T_levels, self.T_vals = np.asarray(transfer[0], float), np.maximum.accumulate(np.asarray(transfer[1], float))
        self._ramp = np.arange(len(self.T_levels)) * 1e-9
        self.values = {}
        self.L = {}
        for (ctrl, value), L in globals_.items():
            self.values.setdefault(ctrl, []).append(value)
            self.L[(ctrl, value)] = np.asarray(L, float)
        for ctrl in list(self.values):
            self.values[ctrl] = sorted(self.values[ctrl])
        self._gains = {}

    def T(self, level):
        return np.interp(level, self.T_levels, self.T_vals)

    def Tinv(self, lstar):
        return np.interp(lstar, self.T_vals + self._ramp, self.T_levels)

    def invertible(self, lstar, margin=0.6):
        """Where an L* lies strictly inside T's range, so that a gain read from it is real."""
        return (np.asarray(lstar) > self.T_vals[0] + margin) & (np.asarray(lstar) < self.T_vals[-1] - margin)

    def has(self, ctrl):
        return ctrl in self.values

    def L_of_value(self, ctrl, value):
        """The columns' L* for `ctrl` at slider `value` (any, interpolated in the value; zero is the base render)."""
        vs = [0.0] + [v for v in self.values[ctrl] if v != 0]
        Ls = [self.T_cols] + [self.L[(ctrl, v)] for v in self.values[ctrl] if v != 0]
        order = np.argsort(vs)
        vs, Ls = np.asarray(vs)[order], np.asarray(Ls)[order]
        value = np.asarray(value, float)
        flat = np.clip(value, vs[0], vs[-1])
        return pchip(vs, Ls, flat.ravel()).reshape(value.shape + (len(self.x),))

    def gain_cols(self, ctrl, value):
        """g at the columns' own levels, stops, for scalar `value`."""
        if ctrl == "E":
            return np.full(len(self.x), float(value))
        key = (ctrl, float(value))
        if key not in self._gains:
            L = self.L_of_value(ctrl, np.array(value))
            self._gains[key] = self.Tinv(np.clip(L, self.T_vals[0], self.T_vals[-1])) - self.x
        return self._gains[key]

    def gain(self, ctrl, value, level):
        """g(level) in stops: the table held constant beyond the ramp's ends."""
        if ctrl == "E":
            return np.full(np.shape(level), float(value))
        return np.interp(level, self.x, self.gain_cols(ctrl, value))

    def layer_local(self, values, level):
        """Highlights then Shadows of one layer at the base `level`: sequential, as a composite table."""
        t = np.zeros(np.shape(level))
        for ctrl in LOCAL_ORDER:
            if values.get(ctrl):
                t = t + self.gain(ctrl, values[ctrl], level + t)
        return t

    def layer_global(self, values, level):
        """Whites, then Blacks, then Contrast of one layer at `level`."""
        t = np.zeros(np.shape(level))
        for ctrl in GLOBAL_ORDER:
            if values.get(ctrl):
                t = t + self.gain(ctrl, values[ctrl], level + t)
        return t

    def r5_level(self, x, xb, panel, layers, coverage, panel_first=True):
        """R5's level after the panel (global sliders `panel`, coverage 1) and `layers` (dicts control -> value, in list order)
        at `coverage` (scalars or arrays that broadcast with x). R5 puts the panel's global gains first; `panel_first=False`
        puts them after the masks' (the other order an expert reports)."""
        e = panel.get("E", 0.0) + sum(c * layer.get("E", 0.0) for layer, c in zip(layers, coverage))
        u, ub = x + e, xb + e
        t = self.layer_local(panel, ub)
        for layer, c in zip(layers, coverage):
            t = t + c * self.layer_local(layer, ub)
        if panel_first:
            t = t + self.layer_global(panel, u + t)
        for layer, c in zip(layers, coverage):
            t = t + c * self.layer_global(layer, u + t)
        if not panel_first:
            t = t + self.layer_global(panel, u + t)
        return u + t

    def r5_lstar(self, x, xb, panel, layers, coverage, panel_first=True):
        return self.T(self.r5_level(x, xb, panel, layers, coverage, panel_first))

    def summed_row(self, panel, layers, coverage):
        """The other reading, for one row of the ramp where every coverage is a scalar: each layer's sliders, scaled by its
        coverage, are summed with the panel's; then one evaluation (Highlights then Shadows at the base, then Whites, Blacks,
        Contrast at the level so far), the render interpolated in the slider value. Exposure adds in stops. Returns the
        columns' L*."""
        sliders = {ctrl: panel.get(ctrl, 0.0) + sum(c * layer.get(ctrl, 0.0) for layer, c in zip(layers, coverage)) for ctrl in "CHSWB"}
        e = panel.get("E", 0.0) + sum(c * layer.get("E", 0.0) for layer, c in zip(layers, coverage))
        u = self.x + e
        t = np.zeros_like(u)
        for ctrl in LOCAL_ORDER:
            if sliders[ctrl] != 0 and self.has(ctrl):
                t = t + np.interp(u + t, self.x, self.gain_cols(ctrl, sliders[ctrl]))
        for ctrl in GLOBAL_ORDER:
            if sliders[ctrl] != 0 and self.has(ctrl):
                t = t + np.interp(u + t, self.x, self.gain_cols(ctrl, sliders[ctrl]))
        return self.T(u + t)


def seq_level(tables, x, steps):
    """The level after applying `steps` [(control, value), ...] one after another, each gain read at the level so far."""
    level = np.array(x, float)
    for ctrl, value in steps:
        level = level + tables.gain(ctrl, value, level)
    return level
