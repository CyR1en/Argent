"""Clarity's positive side, round 2 (Presence program, F1b): the ceiling, the signal, a 2-D local Laplacian filter,
frame adaptation, and F1's constants on frames F1 did not fit.

    python -I fit_clarity_round2.py holdout   step 6: F1's Clarity and Texture constants through the film, held-out frames
    python -I fit_clarity_round2.py ceiling   step 1: what local multi-scale operators explain, frames held out
    python -I fit_clarity_round2.py signal    step 2: which lightness makes the colour chart's hue dependence one law
    python -I fit_clarity_round2.py rounds    steps 1 and 5 on both rounds' photographs: the two splits, adaptation
    python -I fit_clarity_round2.py tone      round 2's tone charts: the pixel's level against the frame's
    python -I fit_clarity_round2.py llf       step 3: the fast local Laplacian filter on gratings, photographs, steps, edge
    python -I fit_clarity_round2.py rule      the outcome rule from the saved scores, the pass bars, constants.json
    python -I fit_clarity_round2.py all       every step in order, about 70 minutes from an empty scratch folder

A spike build with --clarity and --texture, against the held-out bars of `validate/detail/bars.json`, the build and
F1's prototype both rendered under the explicit aim (`aim_flags`):

    python -I fit_clarity_round2.py spike --binary PATH [--frames J ...] [--stocks S ...] [--slider S] [--no-parity]
                                          [--scratch DIR] [--runs FILE]
    python -I fit_clarity_round2.py spike-bars --runs FILE        bars.json from a full `spike` run's prototype scores
    python -I fit_clarity_round2.py spike-check [--frames J ...] ...   `spike` on a stand-in build (emulate_spike)
    python -I fit_clarity_round2.py spike-protocols --binary PATH --frames J ... [--scratch DIR] [--out FILE]
                                          parity under --auto and the explicit aim, and with the stock's neutral transfer

F1's module (`fit_texture_clarity`) supplies the readers, the film frame and F1's candidates; it is imported, never
edited. Its cache folder is pointed at this round's own scratch folder so nothing is written into F1's evidence.
"""
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fit_dehaze as FD  # noqa: E402
import fit_texture_clarity as F  # noqa: E402
import probe  # noqa: E402
import scene_io  # noqa: E402

EVIDENCE = F.EVIDENCE
OUT = EVIDENCE / "fit" / "clarity-round2"
F1_OUT = EVIDENCE / "fit" / "texture-clarity"
F.OUT = OUT
SCRATCH = OUT / "scratch"
ROUND2 = EVIDENCE / "probe" / "round2" / "manifest.json"

# The split, fixed before any score: F1 fitted its tone weights and laws on these four frames; the other seven
# photographs of round 1 are held out. Round 2's photographs, when they exist, are held out too.
FIT = ("p-raw", "p-photo-sky", "p-photo-texture", "p-photo-iso")
HELD = ("p-photo-hazy", "p-photo-skin", "p-photo-saturated", "p-photo-foliage", "p-photo-night", "p-photo-flat",
        "p-photo-contrast")
VALUES = (-100, -50, 50, 100)


def round2_jobs(kind="photo"):
    if not ROUND2.exists():
        return ()
    return tuple(j["name"] for j in json.loads(ROUND2.read_text())["jobs"] if j.get("kind") == kind)


ROUND2_PHOTOS = round2_jobs()
_round1_raw = F.raw_of


def raw_of(job):
    """The raw behind a photograph of either round."""
    if job.startswith("q-"):
        return Path(next(j["source"] for j in json.loads(ROUND2.read_text())["jobs"] if j["name"] == job))
    return _round1_raw(job)


def photo_blocks(job):
    """F1's `photo_blocks` for either round: Lightroom's renders on 4 x 4 blocks, only those that exist (round 2 has
    Texture at +-100 only), cached in this round's scratch folder."""
    path = SCRATCH / f"blocks-{job}.npz"
    if path.exists():
        return dict(np.load(path))
    out = {"base": probe.block_mean(F.read_y(F.export_path(job)))}
    for slider in F.SLIDERS:
        for v in (F.RAW_VALUES if job == "p-raw" else F.PHOTO_VALUES):
            if F.export_path(job, slider, v).exists():
                out[f"{slider}{v:+d}"] = probe.block_mean(F.read_y(F.export_path(job, slider, v)))
    np.savez(path, **out)
    return out


F.raw_of, F.photo_blocks = raw_of, photo_blocks


def f1_constants():
    return json.loads((F1_OUT / "constants.json").read_text())["candidates"]


def export_shape(job):
    _, h, w, _ = F._strip(F.export_path(job))
    return h, w


def save(name, data):
    (OUT / name).write_text(json.dumps(data, indent=0))


# MARK: Step 6. F1's constants, unchanged, on the frames F1 did not use

def run_holdout(jobs=HELD, stocks=F.SCORE_STOCKS, out_name="holdout-f1.json"):
    """Clarity (both signs) and Texture with F1's fitted constants through Argent's film on `jobs`: the same metrics,
    flags and blocks as F1's `run_score`, Texture also per pixel on the frame's central 2048 crop."""
    constants = f1_constants()
    out = []
    for job in jobs:
        shape = export_shape(job)
        crop = F.central_crop(shape)
        for stock in stocks:
            t0 = time.time()
            frame = F.FilmFrame(job, stock, crop=crop)
            if frame.Y.shape != shape:
                raise SystemExit(f"{job}: Argent's decode is {frame.Y.shape}, Lightroom's export {shape}")
            for name, slider in (("clarity-guided", "clarity"), ("texture-guided-band", "texture")):
                c = constants[name]
                details = {key: F.make_detail(c[key], frame.Y, frame.g) for key in ("positive", "negative")}
                for v in VALUES:
                    key, lr_key = ("positive" if v > 0 else "negative"), f"{slider}{v:+d}"
                    if lr_key not in frame.lr:
                        continue
                    blocks, crop_lstar = frame.render(frame.delta(c[key], v, details[key]))
                    row = {"candidate": name, "job": job, "stock": stock, "value": v,
                           **F.scores(blocks - frame.L0, frame.lr_change(lr_key), frame.valid),
                           "floor": float(np.sqrt(np.mean(frame.floor(lr_key)[frame.valid] ** 2)))}
                    if slider == "texture":
                        row.update({f"crop_{m}": x for m, x in
                                    F.scores(crop_lstar - frame.L0c, frame.lr_crop_change(lr_key), frame.validc).items()})
                    out.append(row)
                    print(f"  {name:20s} {job:18s} {stock:17s} {v:+4d} rmse {row['rmse']:5.2f} r2 {row['r2']:+.3f} "
                          f"floor {row['floor']:4.2f}" + (f" crop {row['crop_rmse']:4.2f} {row['crop_r2']:+.3f}"
                                                          if slider == "texture" else ""), flush=True)
                del details
            del frame
            print(f"  {job} {stock}: {time.time() - t0:.0f} s", flush=True)
            save(out_name, out)
    return out


def holdout_table(rows=None):
    """Held-out means beside F1's in-sample means (F1's own score files), per candidate and value: "held" is round 1's
    seven frames, "round2" round 2's twenty."""
    rows = rows or json.loads((OUT / "holdout-f1.json").read_text())
    path2 = OUT / "holdout-f1-round2.json"
    rows2 = json.loads(path2.read_text()) if path2.exists() else []
    insample = {"clarity-guided": json.loads((F1_OUT / "scores-clarity-film.json").read_text()),
                "texture-guided-band": json.loads((F1_OUT / "scores-texture-film.json").read_text())}
    lines = []
    for name in ("clarity-guided", "texture-guided-band"):
        metrics = ("rmse", "r2", "floor") + (("crop_rmse", "crop_r2") if name.startswith("texture") else ())
        for v in VALUES + ("all",):
            for label, rs in (("held", rows), ("round2", rows2), ("in", insample[name])):
                sel = [r for r in rs if r["candidate"] == name and (v == "all" or r["value"] == v)]
                if sel:
                    lines.append({"candidate": name, "value": v, "set": label, "runs": len(sel),
                                  **{m: round(float(np.mean([r[m] for r in sel])), 3) for m in metrics},
                                  "rmse_spread": [round(float(np.min([r["rmse"] for r in sel])), 2),
                                                  round(float(np.max([r["rmse"] for r in sel])), 2)]})
    return lines


# MARK: Lightroom's renders of the eleven photographs on the scorecard's blocks

PHOTOS = FIT + HELD
CLARITY_KEYS = tuple(f"clarity{v:+d}" for v in VALUES)


def lr_blocks(job):
    """Lightroom's base and Clarity renders of a photograph on 4 x 4 blocks: linear Y per render, the base's linear
    ProPhoto RGB, and the base's within-block spread of log2 Y (detail finer than a block). Cached in scratch."""
    path = SCRATCH / f"lr-{job}.npz"
    if path.exists():
        return dict(np.load(path))
    rgb = F.read_rgb(F.export_path(job))
    out = {"rgb": np.stack([probe.block_mean(rgb[..., c]) for c in range(3)], axis=-1).astype(np.float32)}
    Y = rgb @ F.PROPHOTO_Y.astype(np.float32)
    del rgb
    g = np.log2(np.maximum(Y, 2.0 ** -16))
    out["base"] = probe.block_mean(Y).astype(np.float32)
    out["fine"] = np.sqrt(np.maximum(probe.block_mean(g * g) - probe.block_mean(g) ** 2, 0)).astype(np.float32)
    del Y, g
    for key in CLARITY_KEYS:
        out[key] = probe.block_mean(F.read_y(F.export_path(job, *F.split_key(key)))).astype(np.float32)
    np.savez(path, **out)
    return out


def valid_blocks(b, key):
    L0, Lv = probe.lstar(b["base"].astype(np.float64)), probe.lstar(b[key].astype(np.float64))
    return (L0 > 0.5) & (L0 < 99.5) & (Lv > 0.5) & (Lv < 99.5)


# MARK: Step 1. The ceiling: a flexible local multi-scale regression, its Gram matrices kept per frame

LEVELS = 9
TONE_KNOTS = (-10.0, -8.0, -6.0, -4.5, -3.0, -1.5, 0.0)
REL_KNOTS = (-6.0, -4.0, -2.0, -1.0, 0.0, 1.0, 2.0)
AMP_KNOTS = (0.0, 0.05, 0.1, 0.2, 0.4, 0.8, 1.6)
EDGE_KNOTS = (0.0, 0.3, 0.8, 2.0)
GLOBAL_KNOTS = tuple(np.linspace(-12.0, 0.0, 13))
SAMPLES = 150_000


def hats(x, knots):
    """Piecewise-linear hat functions on `knots`, clamped outside: a partition of unity, shape (len(knots),) + x.shape."""
    k = np.asarray(knots, np.float64)
    t = np.clip(np.interp(x, k, np.arange(len(k), dtype=np.float64)), 0, len(k) - 1)
    i = np.minimum(np.floor(t).astype(np.int64), len(k) - 2)
    f = (t - i).astype(np.float32)
    out = np.zeros((len(k),) + np.shape(x), np.float32)
    for j in range(len(k)):
        out[j] = np.where(i == j, 1 - f, 0) + np.where(i == j - 1, f, 0)
    return out


def gaussian_levels(x, levels):
    out = [x.astype(np.float32)]
    for _ in range(levels):
        out.append(F._down(out[-1]))
    return out


def lift(c, shapes):
    """A coefficient map at level len(shapes) brought to the finest level through the pyramid's own upsampling,
    as collapse() brings a level: shapes[j] is the shape of level j."""
    for s in reversed(shapes):
        c = F._up(c, s)
    return c


def feature_groups(gb):
    """Yield (group, name, image) for every feature of the ceiling regression, from the base's block log2 Y `gb`.

    Per Laplacian level l (0 finest): the level's coefficient times hats of the local tone T_l (the next level's
    Gaussian, in log2 Y), of the tone relative to the frame's median, of the local spread A_l (the Gaussian-weighted
    standard deviation of g over level l+1's footprint), of their product, and of a coarser spread A_{l+2} (an edge
    nearby). Each map is lifted to the block grid, so the model is any sum of per-level, per-amplitude, per-tone
    gains: what a local multi-scale operator of this signal can do. Global groups add hats of the block's own level
    and of a coarse local mean (a tone curve and a very-low-frequency change)."""
    G = gaussian_levels(gb, LEVELS + 2)
    G2 = gaussian_levels(gb * gb, LEVELS + 2)
    shapes = [x.shape for x in G]
    median = float(np.median(gb))
    spread = [np.sqrt(np.maximum(G2[l] - G[l] ** 2, 0)) for l in range(LEVELS + 2)]
    yield "intercept", "1", np.ones_like(gb)
    for l in range(LEVELS):
        L = G[l] - F._up(G[l + 1], shapes[l])
        T = F._up(G[l + 1], shapes[l])
        A = F._up(spread[l + 1], shapes[l])
        Ae = F._up(F._up(spread[l + 2], shapes[l + 1]), shapes[l])
        up = shapes[:l]
        yield "bands", f"L{l}", lift(L, up)
        ht, ha = hats(T, TONE_KNOTS), hats(A, AMP_KNOTS)
        for j in range(len(TONE_KNOTS)):
            yield "tone", f"L{l} t{j}", lift(L * ht[j], up)
        for j, h in enumerate(hats(T - median, REL_KNOTS)):
            yield "relative", f"L{l} r{j}", lift(L * h, up)
        for j in range(len(AMP_KNOTS)):
            yield "amp", f"L{l} a{j}", lift(L * ha[j], up)
            for i in range(len(TONE_KNOTS)):
                yield "amptone", f"L{l} a{j} t{i}", lift(L * ha[j] * ht[i], up)
        for j, h in enumerate(hats(Ae, EDGE_KNOTS)):
            yield "edge", f"L{l} e{j}", lift(L * h, up)
        del L, T, A, Ae, ht, ha
    for j, h in enumerate(hats(gb, GLOBAL_KNOTS)):
        yield "global", f"g {j}", h
    coarse = lift(G[6], shapes[:6])
    for j, h in enumerate(hats(coarse, GLOBAL_KNOTS)):
        yield "global", f"G6 {j}", h


def f1_detail_columns(b, gb):
    """F1's recommended positive D (guided, 1024 field, radius 0.08, epsilon 1) on Lightroom's base blocks, alone and
    times hats of the base's L* (F1's tone weight), so the regression reproduces F1's own numbers."""
    a, c = F.guided_coefficients(b["base"].astype(np.float64), 1024, 0.08, 1.0)
    D = (gb - probe.ToneBase.sample(a, gb.shape) * gb - probe.ToneBase.sample(c, gb.shape)).astype(np.float32)
    yield "f1", "D", D
    Lb = probe.lstar(np.exp2(gb - D).astype(np.float64))
    for j, h in enumerate(hats(Lb, F.LSTAR_KNOTS)):
        yield "f1tone", f"D m{j}", D * h


RELATIVE_CURVE_KNOTS = (-7.0, -5.0, -4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0)
COARSE_KNOTS = (-4.0, -2.5, -1.5, -0.75, 0.0, 0.75, 1.5, 3.0)
COARSE_SIGMAS = (16, 48, 128, 320)


def blur(x, sigma):
    """A Gaussian of `sigma` pixels as three box passes with clamped edges."""
    r = max(1, int(round(np.sqrt(12 * sigma ** 2 / 3 + 1) / 2 - 0.5)))
    for _ in range(3):
        x = probe.box(x, r)
    return x


def global_groups(gb):
    """Candidates for the frame-adaptive tone part: hats of the block's level less the frame's median and less its
    mean (a curve that moves with the frame), and hats of the level less a coarse local mean at several widths (a
    nonlinear contrast at the largest scales), with the absolute level's hats beside them."""
    yield "intercept", "1", np.ones_like(gb)
    for j, h in enumerate(hats(gb, GLOBAL_KNOTS)):
        yield "global", f"g {j}", h
    for label, ref in (("median", np.median(gb)), ("mean", gb.mean())):
        for j, h in enumerate(hats(gb - ref, RELATIVE_CURVE_KNOTS)):
            yield f"rel-{label}", f"{label} {j}", h
    for s in COARSE_SIGMAS:
        rel = gb - blur(gb.astype(np.float64), s).astype(np.float32)
        for j, h in enumerate(hats(rel, COARSE_KNOTS)):
            yield f"coarse{s}", f"c{s} {j}", h
        del rel


SIGNALS = {
    "Y": lambda rgb: rgb @ F.PROPHOTO_Y.astype(np.float32),
    "mean": lambda rgb: rgb.mean(axis=-1),
    "hsl": lambda rgb: (rgb.max(axis=-1) + rgb.min(axis=-1)) / 2,
    "rms": lambda rgb: np.sqrt((rgb * rgb).mean(axis=-1)),
    "max": lambda rgb: rgb.max(axis=-1),
}


def signal_groups(b, gb):
    """Clarity's weight, detail and tone curve read on other lightness signals S of the base's linear ProPhoto RGB:
    per S, F1's D made from log2 S, F1's D (from luminance) and D_S times hats of the L* of S's guided base, and
    curves of log2 S less its frame median and of log2 S itself."""
    yield "intercept", "1", np.ones_like(gb)
    D = next(f1_detail_columns(b, gb))[2]
    for name, f in SIGNALS.items():
        S = np.maximum(f(b["rgb"]), 2.0 ** -16).astype(np.float64)
        gs = np.log2(S).astype(np.float32)
        a, c = F.guided_coefficients(S, 1024, 0.08, 1.0)
        base = probe.ToneBase.sample(a, gs.shape) * gs + probe.ToneBase.sample(c, gs.shape)
        Ds = (gs - base).astype(np.float32)
        level = hats(probe.lstar(np.exp2(base)), F.LSTAR_KNOTS)
        yield f"{name} DS", f"{name} DS", Ds
        for j, h in enumerate(level):
            yield f"{name} D x tone", f"{name} D m{j}", D * h
            yield f"{name} DS x tone", f"{name} DS m{j}", Ds * h
        for j, h in enumerate(hats(gs - np.median(gs), RELATIVE_CURVE_KNOTS)):
            yield f"{name} median curve", f"{name} med {j}", h
        for j, h in enumerate(hats(gs, GLOBAL_KNOTS)):
            yield f"{name} curve", f"{name} g {j}", h
        del S, gs, base, Ds, level


FEATURES = {"full": lambda b, gb: feature_groups(gb), "global": lambda b, gb: global_groups(gb),
            "signal": lambda b, gb: signal_groups(b, gb)}


def frame_gram(job, kind="full", make=None):
    """The ceiling regression's sufficient statistics for one photograph: X'X over a fixed sample of blocks valid in
    every Clarity render, and per Clarity value X'y, y'y, sum y and n. `kind` names the features (FEATURES, or `make`
    for others such as the LLF's); F1's D and its tone weight are always included. Cached in scratch."""
    path = SCRATCH / f"gram-{job}{'' if kind == 'full' else '-' + kind}.npz"
    if not path.exists():
        _gram_from_sources(job, path, make or FEATURES[kind])
    z = np.load(path)
    return {k: z[k] for k in z.files}


def gram(A, B, chunk=20000):
    out = np.zeros((A.shape[1], B.shape[1]))
    for s in range(0, A.shape[0], chunk):
        out += A[s:s + chunk].astype(np.float64).T @ B[s:s + chunk].astype(np.float64)
    return out


MODELS = {
    "F1 D": ("f1",),
    "F1 D x tone weight": ("f1tone",),
    "global tone curve only": ("intercept", "global"),
    "linear bands": ("intercept", "bands"),
    "bands x tone": ("intercept", "tone"),
    "bands x frame-relative tone": ("intercept", "relative"),
    "bands x amplitude": ("intercept", "amp"),
    "bands x amplitude x tone": ("intercept", "amptone"),
    "+ edge context": ("intercept", "amptone", "edge"),
    "+ relative tone": ("intercept", "amptone", "edge", "relative"),
    "+ global tone": ("intercept", "amptone", "edge", "relative", "global"),
    "everything (with F1's D)": ("intercept", "amptone", "edge", "relative", "global", "tone", "bands", "f1", "f1tone"),
}
LAMBDAS = (1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1.0)
# What a frame may refit on top of a common model, to measure what each kind of frame adaptation is worth.
ORACLES = {"offset": ("intercept",), "scale+offset": ("scale", "intercept"), "curve": ("intercept", "curve"),
           "scale+curve": ("scale", "intercept", "curve")}


class Ceiling:
    """Ridge fits and their R2 from per-frame Gram matrices: any column groups, any frames to fit, any to score."""

    def __init__(self, jobs, kind="full", make=None):
        self.g = {j: frame_gram(j, kind, make) for j in jobs}
        first = next(iter(self.g.values()))
        self.names, self.groups = first["names"], first["groups"]
        self.one = int(np.flatnonzero(self.names == "1")[0])
        # The block's own level as hats (the "g j" columns): a per-frame tone curve when refitted per frame.
        self.curve = np.array([str(n).startswith("g ") for n in self.names])

    def mask(self, groups):
        return np.isin(self.groups, groups)

    def fit(self, jobs, mask, key, lam):
        """Ridge on the raw columns (all in stops or in 0..1 hats), the weight a share of the mean diagonal."""
        XtX = sum(self.g[j]["XtX"][np.ix_(mask, mask)] for j in jobs)
        Xty = sum(self.g[j][f"Xty {key}"][mask] for j in jobs)
        pen = lam * np.trace(XtX) / mask.sum() * np.eye(mask.sum())
        free = self.names[mask] == "1"
        pen[free, free] = 0
        return np.linalg.solve(XtX + pen, Xty)

    def r2(self, job, mask, key, beta, oracle=()):
        """1 - SSE / SST on one frame and value, SST about the frame's own mean change. `oracle` names what the frame
        refits on the common model's residual: "scale" (of the prediction), "intercept" (its mean), "curve" (a tone
        curve of the block's own level)."""
        g = self.g[job]
        XtX, Xy = g["XtX"], g[f"Xty {key}"]
        yty, sy, n = float(g[f"yty {key}"]), float(g[f"sy {key}"]), float(g["n"])
        sst = yty - sy * sy / n
        XMb = XtX[:, mask] @ beta
        pp, py = float(beta @ XMb[mask]), float(beta @ Xy[mask])
        rr = yty - 2 * py + pp
        if not oracle:
            return 1 - rr / sst
        O = np.zeros(len(self.names), bool)
        if "intercept" in oracle:
            O[self.one] = True
        if "curve" in oracle:
            O |= self.curve
        idx = np.flatnonzero(O)
        QQ, Qr = XtX[np.ix_(idx, idx)], Xy[idx] - XMb[idx]
        if "scale" in oracle:
            QQ = np.block([[np.array([[pp]]), XMb[idx][None, :]], [XMb[idx][:, None], QQ]])
            Qr = np.concatenate([[py - pp], Qr])
        gamma = np.linalg.solve(QQ + 1e-9 * np.trace(QQ) / len(QQ) * np.eye(len(QQ)), Qr)
        return 1 - (rr - gamma @ Qr) / sst

    def heldout(self, fit_jobs, test_jobs, mask, key, lam, oracle=()):
        beta = self.fit(fit_jobs, mask, key, lam)
        return {j: self.r2(j, mask, key, beta, oracle) for j in test_jobs}

    def choose_lambda(self, fit_jobs, mask, key):
        """The ridge weight by leave-one-frame-out inside the fitting frames only."""
        scores = [np.mean([self.heldout([f for f in fit_jobs if f != j], [j], mask, key, lam)[j] for j in fit_jobs])
                  for lam in LAMBDAS]
        return LAMBDAS[int(np.argmax(scores))]


GLOBAL_MODELS = {
    "common curve, absolute level": ("intercept", "global"),
    "common curve, level less frame median": ("intercept", "rel-median"),
    "common curve, level less frame mean": ("intercept", "rel-mean"),
    **{f"coarse contrast, sigma {s} blocks": ("intercept", f"coarse{s}") for s in COARSE_SIGMAS},
    "coarse contrast, all widths": ("intercept",) + tuple(f"coarse{s}" for s in COARSE_SIGMAS),
    "F1 D x tone + median curve": ("intercept", "f1tone", "rel-median"),
    "F1 D x tone + coarse, all widths": ("intercept", "f1tone") + tuple(f"coarse{s}" for s in COARSE_SIGMAS),
    "F1 D x tone + median curve + coarse": ("intercept", "f1tone", "rel-median") + tuple(f"coarse{s}" for s in COARSE_SIGMAS),
}


SIGNAL_MODELS = {}
for _s in SIGNALS:
    SIGNAL_MODELS[f"{_s}: F1 D x tone({_s})"] = ("intercept", f"{_s} D x tone")
    SIGNAL_MODELS[f"{_s}: D_S x tone({_s})"] = ("intercept", f"{_s} DS x tone")
    SIGNAL_MODELS[f"{_s}: D_S x tone + median curve"] = ("intercept", f"{_s} DS x tone", f"{_s} median curve")
    SIGNAL_MODELS[f"{_s}: F1 D x tone + median curve"] = ("intercept", f"{_s} D x tone", f"{_s} median curve")


def run_ceiling(kind="full", keys=CLARITY_KEYS):
    c = Ceiling(PHOTOS, kind)
    models = {"full": MODELS, "global": GLOBAL_MODELS, "signal": SIGNAL_MODELS}[kind]
    rows = []
    for name, groups in models.items():
        mask = c.mask(groups)
        for key in keys:
            row = {"model": name, "value": key, "columns": int(mask.sum())}
            # In-frame: each frame fitted on itself, the most this column set can express with per-frame constants.
            row["in_frame"] = np.mean([c.heldout([j], [j], mask, key, LAMBDAS[0])[j] for j in PHOTOS])
            lam = c.choose_lambda(FIT, mask, key)
            row["lambda"] = lam
            per = c.heldout(FIT, HELD, mask, key, lam)
            row["held"] = float(np.mean(list(per.values())))
            row["held_per_frame"] = {j: round(float(v), 3) for j, v in per.items()}
            for label, oracle in ORACLES.items():
                row[f"held+{label}"] = float(np.mean(list(c.heldout(FIT, HELD, mask, key, lam, oracle).values())))
            row["held_best_lambda"] = max(np.mean(list(c.heldout(FIT, HELD, mask, key, l).values())) for l in LAMBDAS)
            lam11 = c.choose_lambda(PHOTOS, mask, key)
            row["lofo11"] = float(np.mean([c.heldout([f for f in PHOTOS if f != j], [j], mask, key, lam11)[j]
                                           for j in PHOTOS]))
            row["lofo11+scale+offset"] = float(np.mean([c.heldout([f for f in PHOTOS if f != j], [j], mask, key, lam11,
                                                                  ORACLES["scale+offset"])[j] for j in PHOTOS]))
            row["pooled_in_sample"] = float(np.mean([c.heldout(PHOTOS, [j], mask, key, LAMBDAS[0])[j] for j in PHOTOS]))
            row["pooled+scale+offset"] = float(np.mean([c.heldout(PHOTOS, [j], mask, key, LAMBDAS[0],
                                                                  ORACLES["scale+offset"])[j] for j in PHOTOS]))
            rows.append({k: (round(float(v), 4) if isinstance(v, (float, np.floating)) else v) for k, v in row.items()})
            print(f"  {name:26s} {key:12s} {row['columns']:4d} | in-frame {row['in_frame']:.3f} | held {row['held']:.3f} "
                  f"+off {row['held+offset']:.3f} +s+off {row['held+scale+offset']:.3f} +curve {row['held+curve']:.3f} "
                  f"+s+curve {row['held+scale+curve']:.3f} best-lam {row['held_best_lambda']:.3f} | lofo11 "
                  f"{row['lofo11']:.3f} (+s+off {row['lofo11+scale+offset']:.3f}) | pooled {row['pooled_in_sample']:.3f} "
                  f"(+s+off {row['pooled+scale+offset']:.3f})", flush=True)
    return rows


def change_split(job):
    """Lightroom's Clarity change on one photograph: its mean in stops and in L*, the share of its variance a tone
    curve of the base's own level explains on this frame (the curve's values at GLOBAL_KNOTS kept), and the share of
    its variance at scales finer than each Gaussian level's footprint (2**l blocks, 4 * 2**l frame pixels)."""
    b = lr_blocks(job)
    gb = np.log2(np.maximum(b["base"], 2.0 ** -16))
    out = {}
    for key in CLARITY_KEYS:
        ok = valid_blocks(b, key)
        d = np.log2(np.maximum(b[key], 2.0 ** -16)) - gb
        dL = probe.lstar(b[key].astype(np.float64)) - probe.lstar(b["base"].astype(np.float64))
        filled = np.where(ok, d, np.median(d[ok])).astype(np.float32)
        G = gaussian_levels(filled, LEVELS + 1)
        shapes = [x.shape for x in G]
        var = float(np.var(d[ok]))
        fine = [round(float(np.var((filled - lift(G[l], shapes[:l]))[ok]) / var), 4) for l in range(1, LEVELS + 2)]
        H = hats(gb[ok], GLOBAL_KNOTS).reshape(len(GLOBAL_KNOTS), -1).T.astype(np.float64)
        coef, *_ = np.linalg.lstsq(H, d[ok].astype(np.float64), rcond=None)
        counts = H.sum(axis=0)
        out[key] = {"mean_stops": float(d[ok].mean()), "mean_lstar": float(dL[ok].mean()),
                    "rms_stops": float(np.sqrt(np.mean(d[ok] ** 2))), "sd_stops": float(np.sqrt(var)),
                    "tone_curve_r2": float(1 - np.var(d[ok] - H @ coef) / var),
                    "tone_curve": [round(float(v), 3) if n > 200 else None for v, n in zip(coef, counts)],
                    "finer_than_level": fine}
    return out


# MARK: Both rounds: the ceiling's key models on every held-out frame, and frame adaptation (step 5)

KEY_MODELS = {
    "F1 D x tone weight": ("full", ("f1tone",)),
    "everything (with F1's D)": ("full", MODELS["everything (with F1's D)"]),
    "bands x amplitude x tone + edge": ("full", ("intercept", "amptone", "edge")),
    "common curve, level less frame median": ("global", ("intercept", "rel-median")),
    "coarse contrast, all widths": ("global", GLOBAL_MODELS["coarse contrast, all widths"]),
    "F1 D x tone + median curve": ("global", GLOBAL_MODELS["F1 D x tone + median curve"]),
    "F1 D x tone + median curve + coarse": ("global", GLOBAL_MODELS["F1 D x tone + median curve + coarse"]),
}


def run_both_rounds(keys=("clarity+50", "clarity+100")):
    """Split A (the rule's): fit on F1's four frames, score round 1's other seven and round 2's twenty. Split B (step
    5): fit on round 1's eleven, score round 2's twenty. Strict R2, and with a per-frame scale and offset or tone
    curve refitted (the oracles), mean over frames."""
    jobs = PHOTOS + ROUND2_PHOTOS
    ceilings = {kind: Ceiling(jobs, kind) for kind in ("full", "global")}
    rows = []
    for name, (kind, groups) in KEY_MODELS.items():
        c = ceilings[kind]
        mask = c.mask(groups)
        for key in keys:
            row = {"model": name, "value": key, "columns": int(mask.sum()),
                   "in_frame_round2": float(np.mean([c.heldout([j], [j], mask, key, LAMBDAS[0])[j] for j in ROUND2_PHOTOS]))}
            for split, fit, tests in (("A", FIT, {"held7": HELD, "round2": ROUND2_PHOTOS}), ("B", PHOTOS, {"round2": ROUND2_PHOTOS})):
                lam = c.choose_lambda(fit, mask, key)
                for label, test in tests.items():
                    row[f"{split} {label}"] = float(np.mean(list(c.heldout(fit, test, mask, key, lam).values())))
                    for o in ("scale+offset", "curve"):
                        row[f"{split} {label} +{o}"] = float(np.mean(list(c.heldout(fit, test, mask, key, lam, ORACLES[o]).values())))
                if split == "B":
                    row["B round2 per frame"] = {j: round(float(v), 3) for j, v in c.heldout(fit, ROUND2_PHOTOS, mask, key, lam).items()}
            rows.append(row)
            print(f"  {name:38s} {key:12s} | A: held7 {row['A held7']:.3f} round2 {row['A round2']:.3f} "
                  f"(+s+off {row['A round2 +scale+offset']:.3f}, +curve {row['A round2 +curve']:.3f}) | B: round2 "
                  f"{row['B round2']:.3f} (+s+off {row['B round2 +scale+offset']:.3f}, +curve {row['B round2 +curve']:.3f}) | "
                  f"in-frame round2 {row['in_frame_round2']:.3f}", flush=True)
    return rows


def frame_statistics(job):
    """Candidate statistics a frame's Clarity strength could follow, on Lightroom's base blocks (log2 Y)."""
    b = lr_blocks(job)
    g = np.log2(np.maximum(b["base"], 2.0 ** -16)).astype(np.float64)
    D = next(f1_detail_columns(b, g.astype(np.float32)))[2]
    coarse = g - blur(g, 128)
    return {"median": float(np.median(g)), "mean": float(g.mean()), "p10": float(np.percentile(g, 10)),
            "p90": float(np.percentile(g, 90)), "spread": float(np.percentile(g, 90) - np.percentile(g, 10)),
            "log linear mean": float(np.log2(b["base"].mean())), "detail rms": float(np.sqrt(np.mean(D * D))),
            "coarse rms": float(np.sqrt(np.mean(coarse * coarse))), "fine rms": float(np.sqrt(np.mean(b["fine"] ** 2))),
            "dark share": float(np.mean(g < np.median(g) - 2))}


def run_adaptation(model="F1 D x tone + median curve", keys=("clarity+50", "clarity+100")):
    """Step 5 on split B: the common model fitted on round 1's eleven frames; each round-1 frame's own best scale and
    offset of its prediction; each regressed on one frame statistic over round 1; applied to round 2's twenty. Held-out
    R2 with the predicted scale and offset, against the common model's and against the oracle's."""
    kind, groups = KEY_MODELS[model]
    jobs = PHOTOS + ROUND2_PHOTOS
    c = Ceiling(jobs, kind)
    mask = c.mask(groups)
    stats = {j: frame_statistics(j) for j in jobs}
    out = {"statistics": stats, "rows": []}
    for key in keys:
        lam = c.choose_lambda(PHOTOS, mask, key)
        beta = c.fit(PHOTOS, mask, key, lam)

        def parts(j):
            g = c.g[j]
            XMb = g["XtX"][:, mask] @ beta
            pp, py, sp = float(beta @ XMb[mask]), float(beta @ g[f"Xty {key}"][mask]), float(XMb[c.one])
            yty, sy, n = float(g[f"yty {key}"]), float(g[f"sy {key}"]), float(g["n"])
            return pp, py, sp, yty, sy, n

        def r2(j, s, o):
            pp, py, sp, yty, sy, n = parts(j)
            sse = yty - 2 * s * py - 2 * o * sy + s * s * pp + 2 * s * o * sp + o * o * n
            return 1 - sse / (yty - sy * sy / n)

        oracle = {}
        for j in jobs:
            pp, py, sp, yty, sy, n = parts(j)
            oracle[j] = np.linalg.solve(np.array([[pp, sp], [sp, n]]), np.array([py, sy]))
        base = float(np.mean([r2(j, 1.0, 0.0) for j in ROUND2_PHOTOS]))
        best = float(np.mean([r2(j, *oracle[j]) for j in ROUND2_PHOTOS]))
        for stat in stats[PHOTOS[0]]:
            x = np.array([stats[j][stat] for j in PHOTOS])
            A = np.stack([np.ones_like(x), x], axis=1)
            cs, *_ = np.linalg.lstsq(A, np.array([oracle[j][0] for j in PHOTOS]), rcond=None)
            co, *_ = np.linalg.lstsq(A, np.array([oracle[j][1] for j in PHOTOS]), rcond=None)
            pred = {j: (cs[0] + cs[1] * stats[j][stat], co[0] + co[1] * stats[j][stat]) for j in ROUND2_PHOTOS}
            held = float(np.mean([r2(j, *pred[j]) for j in ROUND2_PHOTOS]))
            # How well the statistic orders the round-2 frames' own best scales (Spearman's rank correlation).
            xs = np.array([stats[j][stat] for j in ROUND2_PHOTOS])
            ys = np.array([oracle[j][0] for j in ROUND2_PHOTOS])
            rank = float(np.corrcoef(np.argsort(np.argsort(xs)), np.argsort(np.argsort(ys)))[0, 1])
            out["rows"].append({"model": model, "value": key, "statistic": stat, "common": base, "predicted": held,
                                "oracle": best, "rank_corr_round2": rank, "scale_fit": cs.tolist(), "offset_fit": co.tolist()})
            print(f"  {model} {key:12s} {stat:16s} round2 R2: common {base:.3f}  predicted scale+offset {held:.3f}  "
                  f"oracle {best:.3f}  rank corr of scale {rank:+.2f}", flush=True)
        out[f"oracle {key}"] = {j: [round(float(v), 4) for v in oracle[j]] for j in jobs}
    return out


def run_adaptation_lofo(models=("F1 D x tone + median curve", "F1 D x tone weight"), keys=("clarity+50", "clarity+100")):
    """Step 5, a second protocol beside split B: leave one frame out over all 31 frames, so the fitting frames span
    the dark frames round 2 added. Per left-out frame: the common model fitted on the other 30; their own best offsets
    regressed on their median log2 Y; the left-out frame scored with no offset refit, with the offset predicted from
    its median, and with its own best offset (the oracle)."""
    jobs = PHOTOS + ROUND2_PHOTOS
    medians = {j: float(np.median(np.log2(np.maximum(lr_blocks(j)["base"], 2.0 ** -16)))) for j in jobs}
    rows = []
    for model in models:
        kind, groups = KEY_MODELS[model]
        c = Ceiling(jobs, kind)
        mask = c.mask(groups)
        for key in keys:
            lam = c.choose_lambda(FIT, mask, key)
            scores = {"none": [], "median offset": [], "oracle offset": []}
            for j in jobs:
                train = [f for f in jobs if f != j]
                beta = c.fit(train, mask, key, lam)

                def offset(f):
                    g = c.g[f]
                    return (float(g[f"sy {key}"]) - float(beta @ g["XtX"][mask, c.one])) / float(g["n"])

                x = np.array([medians[f] for f in train])
                a_, b_ = np.linalg.lstsq(np.stack([np.ones_like(x), x], 1), np.array([offset(f) for f in train]), rcond=None)[0]
                g = c.g[j]
                XMb = g["XtX"][:, mask] @ beta
                pp, py, sp = float(beta @ XMb[mask]), float(beta @ g[f"Xty {key}"][mask]), float(XMb[c.one])
                yty, sy, n = float(g[f"yty {key}"]), float(g[f"sy {key}"]), float(g["n"])
                sst = yty - sy * sy / n
                for label, o in (("none", 0.0), ("median offset", a_ + b_ * medians[j]), ("oracle offset", offset(j))):
                    sse = yty - 2 * py - 2 * o * sy + pp + 2 * o * sp + o * o * n
                    scores[label].append(1 - sse / sst)
            row = {"model": model, "value": key, **{k: float(np.mean(v)) for k, v in scores.items()},
                   **{f"{k} round2": float(np.mean(v[len(PHOTOS):])) for k, v in scores.items()}}
            rows.append(row)
            print(f"  LOFO 31 {model:28s} {key:12s} R2: no offset {row['none']:.3f}  offset from median "
                  f"{row['median offset']:.3f}  own offset {row['oracle offset']:.3f}   (round 2 only: "
                  f"{row['none round2']:.3f} / {row['median offset round2']:.3f} / {row['oracle offset round2']:.3f})", flush=True)
    return rows


# MARK: Step 2 on the colour chart: which lightness makes Clarity's hue dependence one function

PRO_TO_XYZ = np.array([[0.7976749, 0.1351917, 0.0313534], [0.2880402, 0.7118741, 0.0000857], [0.0, 0.0, 0.8252100]])
PRO_TO_REC2020 = np.linalg.inv(F.scene_io.REC2020_TO_XYZ_D50) @ PRO_TO_XYZ
CHART_SIGNALS = {
    "luminance Y": lambda c: c @ PRO_TO_XYZ[1],
    "mean of Rec. 2020 RGB": lambda c: (PRO_TO_REC2020 @ c).mean(),
    "max of Rec. 2020 RGB": lambda c: (PRO_TO_REC2020 @ c).max(),
    "mean of ProPhoto RGB": lambda c: c.mean(),
    "max of ProPhoto RGB": lambda c: c.max(),
    "min of ProPhoto RGB": lambda c: c.min(),
    "geometric mean": lambda c: float(np.exp(np.log(np.maximum(c, 1e-6)).mean())),
    "HSL lightness (max + min) / 2": lambda c: (c.max() + c.min()) / 2,
    "Rec. 709 weights on ProPhoto": lambda c: c @ [0.2126, 0.7152, 0.0722],
    "Rec. 2020 weights on ProPhoto": lambda c: c @ [0.2627, 0.6780, 0.0593],
    "rms of ProPhoto RGB": lambda c: float(np.sqrt((c * c).mean())),
}


def run_signal_chart(chart="p-colour-texture"):
    """Clarity +100's weight per ground of the colour chart, relative to the neutral ground, two ways: the darkening of
    its flat chroma row (the mean change of log2 Y) and its luminance grating's G - 1 (F1's measure). Then, per
    candidate signal S, how far log2 of that weight is from one power law of S / Y, with S read on Lightroom's base
    render and on the chart's own scene values (ProPhoto, before Lightroom's tone curve)."""
    pro_to_rec = PRO_TO_REC2020
    measured = json.loads((F1_OUT / "measure.json").read_text())["colour"]["clarity+100"]
    B, C = F.read_rgb(F.export_path(chart)), F.read_rgb(F.export_path(chart, "clarity", 100))
    base, scene, dark = {}, {}, {}
    for r in F.layout(chart)["regions"]:
        if r["kind"] == "chroma grating" and r["periodPx"] == 4:
            y0, y1 = r["box"][1] + 48, r["box"][3] - 48
            b, c = B[y0:y1].reshape(-1, 3).mean(0), C[y0:y1].reshape(-1, 3).mean(0)
            base[r["ground"]], dark[r["ground"]] = b, float(np.log2((c @ PRO_TO_XYZ[1]) / (b @ PRO_TO_XYZ[1])))
            scene[r["ground"]] = np.linalg.solve(pro_to_rec, np.array(r["groundTruth"]["rgb"]))
    grounds = list(base)
    gain = {gr: np.mean([m["gain"] - 1 for m in measured if m["kind"] == "luminance grating" and m["ground"] == gr
                         and m["period"] <= 64]) for gr in grounds}
    w_dark = np.array([dark[gr] / dark["neutral"] for gr in grounds])
    w_gain = np.array([gain[gr] / gain["neutral"] for gr in grounds])
    logw = np.log2((w_dark + w_gain) / 2)
    out = {"grounds": grounds, "weight_from_darkening": w_dark.round(3).tolist(), "weight_from_gain": w_gain.round(3).tolist(),
           "darkening_stops": [round(dark[gr], 3) for gr in grounds], "fits": []}
    print("  weight from darkening", dict(zip(grounds, w_dark.round(3))), flush=True)
    print("  weight from gain     ", dict(zip(grounds, w_gain.round(3))), flush=True)
    for space, src in (("render", base), ("scene", scene)):
        for name, f in CHART_SIGNALS.items():
            x = np.array([np.log2(f(src[gr]) / (src[gr] @ PRO_TO_XYZ[1])) for gr in grounds])
            x = x - x[grounds.index("neutral")]
            slope = float(x @ logw / (x @ x)) if (x @ x) > 0 else 0.0
            rms = float(np.sqrt(np.mean((logw - slope * x) ** 2)))
            out["fits"].append({"space": space, "signal": name, "slope": round(slope, 3), "rms_log2_weight": round(rms, 3),
                                "share_explained": round(1 - rms ** 2 / float(np.mean(logw ** 2)), 3)})
            print(f"  {space:6s} {name:32s} slope {slope:+.2f}  rms of log2 weight left {rms:.3f} of "
                  f"{np.sqrt(np.mean(logw ** 2)):.3f}", flush=True)
    return out


# MARK: Round 2's tone charts: the pixel's level against the frame's

R2_LAYOUTS = EVIDENCE / "probe" / "round2" / "chart-layouts"
TONE_CHARTS = ("q-tone-four", "q-tone-dark", "q-tone-bright", "q-tone-ramp")


def r2_cells(chart):
    """The grating cells of a round-2 chart, read as F1's `grating_cells` reads round 1's."""
    cells = []
    for r in json.loads((R2_LAYOUTS / f"{chart}.json").read_text())["regions"]:
        if r["kind"] != "grating":
            continue
        x0, y0, x1, y1 = r["box"]
        band, trim = y1 - y0, max(1, (x1 - x0) // 6)
        cells.append({"period": float(r["periodPx"]), "amplitude": float(r["amplitudeStops"]), "mean": float(r["meanStops"]),
                      "x0": r["x0"], "rows": (y0 + 3 * band // 8, y1 - 3 * band // 8), "cols": (x0 + trim, x1 - trim),
                      "box": r["box"]})
    return cells


def run_tone_charts():
    """Per tone chart and Clarity value: each grating's gain |C_v / C_0| and phase, the mean change of log2 Y inside
    the grating's box, and on the field 256 to 768 rows above it (the frame's own content beside the grating)."""
    out = {}
    for chart in TONE_CHARTS:
        cells = r2_cells(chart)
        g0 = F.log2y(F.read_y(F.export_path(chart)))
        C0, _ = F.cell_amplitudes(g0, cells)
        rows = {}
        for key in CLARITY_KEYS:
            path = F.export_path(chart, *F.split_key(key))
            if not path.exists():
                continue
            d = F.log2y(F.read_y(path)) - g0
            Cv, clipped = F.cell_amplitudes(g0 + d, cells)
            rows[key] = []
            for c, z0, zv in zip(cells, C0, Cv):
                x0, y0, x1, y1 = c["box"]
                rows[key].append({"mean_stops": c["mean"], "gain": round(float(abs(zv / z0)), 4),
                                  "phase": round(float(np.degrees(np.angle(zv / z0))), 2),
                                  "box_change": round(float(np.nanmean(d[y0:y1, x0:x1])), 4),
                                  "field_above_change": round(float(np.nanmean(d[y0 - 768:y0 - 256, x0:x1])), 4),
                                  "base_level": round(float(np.nanmean(g0[y0:y1, x0:x1])), 3),
                                  "field_above_level": round(float(np.nanmean(g0[y0 - 768:y0 - 256, x0:x1])), 3)})
                print(f"  {chart:14s} {key:12s} grating at {c['mean']:+.1f} st: gain {rows[key][-1]['gain']:.3f} "
                      f"phase {rows[key][-1]['phase']:+.1f}  box change {rows[key][-1]['box_change']:+.3f} st  field above "
                      f"{rows[key][-1]['field_above_change']:+.3f} st (base level {rows[key][-1]['base_level']:+.2f}, "
                      f"field {rows[key][-1]['field_above_level']:+.2f})", flush=True)
        out[chart] = rows
    return out


# MARK: Step 3. The fast local Laplacian filter in two dimensions (Aubry et al. 2014), additive form


def remap_detail(kind, d, sigma, alpha=0.5):
    """The remap's detail term f(i - g0), the output being i + k f: Gaussian (Aubry's detail enhancement), Cauchy
    (a heavy A^-2 tail, as the guided filter's knee), or Paris's power curve (alpha < 1 inside sigma, edges kept,
    no enhancement under 0.02 stop as Paris's noise blend)."""
    if kind == "gauss":
        return d * np.exp(-d * d / (2 * sigma * sigma))
    if kind == "cauchy":
        return d / (1 + (d / sigma) ** 2)
    a = np.abs(d)
    x = np.minimum(a / sigma, 1.0)
    tau = np.clip((a - 0.02) / 0.02, 0, 1)
    tau = tau * tau * (3 - 2 * tau)
    inside = sigma * (tau * x ** alpha + (1 - tau) * x) - np.minimum(a, sigma)
    return (np.sign(d) * np.where(a < sigma, inside, 0)).astype(np.float32)


def llf_levels(g, kind, sigma, levels, alpha=0.5):
    """Per Laplacian level, the fast local Laplacian filter's detail coefficients: for every pyramid sample, the
    level's coefficient of f(g - gamma) interpolated between the two sampled references gamma that bracket the
    sample's own Gaussian value. O = g + k * collapse(levels), exactly linear in k."""
    g = g.astype(np.float32)
    step = 0.75 * sigma
    gammas = np.arange(float(g.min()) - step, float(g.max()) + 2 * step, step)
    G = gaussian_levels(g, levels)
    E = [np.zeros_like(G[l]) for l in range(levels)]
    for gamma in gammas:
        weights = [np.maximum(0, 1 - np.abs(G[l] - gamma) / step) for l in range(levels)]
        if not any(w.any() for w in weights):
            continue
        cur = remap_detail(kind, g - np.float32(gamma), sigma, alpha)
        for l in range(levels):
            nxt = F._down(cur)
            if weights[l].any():
                E[l] += weights[l] * (cur - F._up(nxt, cur.shape))
            cur = nxt
    return E, [x.shape for x in G]


LLF_FAMILIES = {"gauss": (0.1, 0.15, 0.25, 0.4, 0.7), "cauchy": (0.05, 0.1, 0.2, 0.35, 0.6)}
LLF_SETTINGS = [(kind, w, None) for kind, widths in LLF_FAMILIES.items() for w in widths] + \
               [("power", w, 0.5) for w in (0.3, 0.6, 1.2, 2.4)]
CHART_LEVELS = 10


def llf_label(kind, sigma, alpha):
    return f"{kind} {sigma:g}" + (f" a{alpha:g}" if alpha else "")


def llf_cell_responses(chart, kind, sigma, alpha):
    """Per level, the LLF detail's complex amplitude on every grating cell of `chart` over the base's (cached)."""
    path = SCRATCH / f"llf-cells-{chart}-{llf_label(kind, sigma, alpha).replace(' ', '_')}.npy"
    if path.exists():
        return np.load(path)
    m = json.loads((F1_OUT / "measure.json").read_text())["gratings"][chart]
    cells = F.grating_cells(chart)
    C0 = np.array([complex(*z) for z in m["base"]])
    g = F.log2y(F.read_y(F.export_path(chart)))
    g = np.where(np.isfinite(g), g, np.nanmin(g)).astype(np.float32)
    E, shapes = llf_levels(g, kind, sigma, CHART_LEVELS, alpha or 0.5)
    A = np.zeros((len(cells), CHART_LEVELS), complex)
    for l in range(CHART_LEVELS):
        A[:, l] = F.cell_amplitudes(lift(E[l], shapes[:l]), cells)[0] / C0
    np.save(path, A)
    return A


def nnls(M, y, iterations=500):
    """Least squares with every coefficient at least 0 (Lawson and Hanson's active set)."""
    n = M.shape[1]
    k, passive = np.zeros(n), np.zeros(n, bool)
    for _ in range(iterations):
        w = M.T @ (y - M @ k)
        if passive.all() or w[~passive].max() <= 1e-10:
            break
        passive[np.argmax(np.where(passive, -np.inf, w))] = True
        while True:
            z = np.zeros(n)
            z[passive] = np.linalg.lstsq(M[:, passive], y, rcond=None)[0]
            if z[passive].min() > 0:
                k = z
                break
            neg = passive & (z <= 0)
            alpha = np.min(k[neg] / (k[neg] - z[neg]))
            k = k + alpha * (z - k)
            passive &= k > 1e-12
    return k


def fit_cells(A, target, ok, positive=False):
    M = np.concatenate([A[ok].real, A[ok].imag])
    y = np.concatenate([target[ok].real, target[ok].imag])
    k = nnls(M, y) if positive else np.linalg.lstsq(M, y, rcond=None)[0]
    return k, np.abs(A @ k - target)


def llf_grating_fit(chart="p-grating-0", key="clarity+100", settings=LLF_SETTINGS):
    """Each LLF setting on Lightroom's base of a grating chart, its per-level strengths fitted by least squares to
    Lightroom's complex G - 1 at `key`: rms |miss| in gain over the unclipped cells, per amplitude. Then, per remap
    family, every level free to mix that family's widths (a knee decided per scale)."""
    m = json.loads((F1_OUT / "measure.json").read_text())["gratings"][chart]
    target = np.array(m[key]["gain"]) * np.exp(1j * np.radians(m[key]["phase"])) - 1
    ok = ~np.array(m[key]["clipped"])
    amp = np.array([c["amplitude"] for c in m["cells"]])
    period = np.array([c["period"] for c in m["cells"]])
    out, families = {}, {}
    for kind, sigma, alpha in settings:
        A = llf_cell_responses(chart, kind, sigma, alpha)
        families.setdefault(kind, []).append(A)
        k, miss = fit_cells(A, target, ok)
        out[llf_label(kind, sigma, alpha)] = summary_cells(k, miss, ok, amp, A)
    for kind, As in families.items():
        A = np.concatenate(As, axis=1)
        k, miss = fit_cells(A, target, ok)
        out[f"{kind} mixed widths, free signs"] = summary_cells(k, miss, ok, amp, A)
        # A sum of remaps with positive weights is itself a remap: the only mixture that is a local Laplacian filter.
        k, miss = fit_cells(A, target, ok, positive=True)
        out[f"{kind} mixed widths"] = summary_cells(k, miss, ok, amp, A)
    for label, r in out.items():
        print(f"  {chart} {key} {label:20s} rms {r['rms']:.3f} by amplitude {r['rms_by_amplitude']}", flush=True)
    out["_cells"] = {"period": period.tolist(), "amplitude": amp.tolist(), "lightroom_gain": np.abs(1 + target).tolist(),
                     "ok": ok.tolist()}
    return out


def summary_cells(k, miss, ok, amp, A):
    return {"rms": float(np.sqrt(np.mean(miss[ok] ** 2))),
            "rms_by_amplitude": {str(a): round(float(np.sqrt(np.mean(miss[ok & (amp == a)] ** 2))), 3)
                                 for a in (0.05, 0.2, 0.8)},
            "k": [round(float(v), 4) for v in k], "model_gain": np.abs(1 + A @ k).round(4).tolist()}


def llf_photo_groups(b, gb, kind, k_grating):
    """LLF columns on a photograph's blocks for one remap family: every width's every level lifted to the block grid
    (block level l is the frame's level l + 2), the grating setting's sum alone and times hats of the base's L*, the
    median curve."""
    levels = CHART_LEVELS - 2
    widths = LLF_FAMILIES[kind]
    yield "intercept", "1", np.ones_like(gb)
    Dg = np.zeros_like(gb)
    for i, w in enumerate(widths):
        E, shapes = llf_levels(gb, kind, w, levels)
        for l in range(levels):
            D = lift(E[l], shapes[:l])
            yield "llf levels", f"w{w:g} E{l}", D
            Dg += np.float32(k_grating[i * CHART_LEVELS + l + 2]) * D
        del E
    yield "llf grating", "Dg", Dg
    Lb = probe.lstar(np.exp2(gb - Dg).astype(np.float64))
    for j, h in enumerate(hats(Lb, F.LSTAR_KNOTS)):
        yield "llf grating x tone", f"Dg m{j}", Dg * h
    for j, h in enumerate(hats(gb - np.median(gb), RELATIVE_CURVE_KNOTS)):
        yield "rel-median", f"median {j}", h


LLF_MODELS = {
    "LLF, grating setting": ("intercept", "llf grating"),
    "LLF, grating setting x tone": ("intercept", "llf grating x tone"),
    "LLF, grating setting x tone + median curve": ("intercept", "llf grating x tone", "rel-median"),
    "LLF levels x widths, fitted on photos": ("intercept", "llf levels"),
    "LLF levels x widths + grating x tone + median curve": ("intercept", "llf levels", "llf grating x tone", "rel-median"),
    "F1 D x tone (same blocks)": ("f1tone",),
    "F1 D x tone + median curve (same blocks)": ("intercept", "f1tone", "rel-median"),
}


def setting_ceiling(kind, k):
    """A Ceiling whose columns are [1, the grating setting's D (a fixed sum of the cached level columns), the median
    curve], from the cached LLF Grams by a linear change of columns."""
    c = Ceiling.__new__(Ceiling)
    c.g = {}
    for j in PHOTOS:
        z = dict(np.load(SCRATCH / f"gram-{j}-llf-{kind}.npz"))
        names, groups = z["names"], z["groups"]
        lev = [i for i, gname in enumerate(groups) if gname == "llf levels"]
        med = [i for i, gname in enumerate(groups) if gname == "rel-median"]
        one = int(np.flatnonzero(names == "1")[0])
        T = np.zeros((len(names), 2 + len(med)))
        T[one, 0] = 1
        widths = LLF_FAMILIES[kind]
        for i in lev:
            w, l = str(names[i]).split()
            T[i, 1] = k[widths.index(float(w[1:])) * CHART_LEVELS + int(l[1:]) + 2]
        for col, i in enumerate(med):
            T[i, 2 + col] = 1
        c.g[j] = {"XtX": T.T @ z["XtX"] @ T, "n": z["n"],
                  **{f"Xty {key}": T.T @ z[f"Xty {key}"] for key in CLARITY_KEYS},
                  **{f"yty {key}": z[f"yty {key}"] for key in CLARITY_KEYS}, **{f"sy {key}": z[f"sy {key}"] for key in CLARITY_KEYS}}
    c.names = np.array(["1", "Dg"] + [f"median {i}" for i in range(len(med))])
    c.groups = np.array(["intercept", "llf grating"] + ["rel-median"] * len(med))
    c.one, c.curve = 0, np.zeros(len(c.names), bool)
    return c


POSITIVE_MODELS = {"LLF, positive grating setting": ("intercept", "llf grating"),
                   "LLF, positive grating setting + median curve": ("intercept", "llf grating", "rel-median")}


def llf_rows(c, kind, models):
    """Held-out R2 (fit on FIT, scored on HELD) of each model on an LLF Ceiling, with the in-frame and oracle values."""
    rows = []
    for name, groups in models.items():
        mask = c.mask(groups)
        for key in ("clarity+50", "clarity+100"):
            lam = c.choose_lambda(FIT, mask, key)
            held = c.heldout(FIT, HELD, mask, key, lam)
            row = {"family": kind, "model": name, "value": key, "columns": int(mask.sum()), "lambda": lam,
                   "in_frame": float(np.mean([c.heldout([j], [j], mask, key, LAMBDAS[0])[j] for j in PHOTOS])),
                   "held": float(np.mean(list(held.values()))),
                   "held+scale+offset": float(np.mean(list(c.heldout(FIT, HELD, mask, key, lam,
                                                                     ORACLES["scale+offset"]).values()))),
                   "held_per_frame": {j: round(float(v), 3) for j, v in held.items()}}
            rows.append(row)
            print(f"  {kind:7s} {name:52s} {key:12s} cols {row['columns']:3d} in-frame {row['in_frame']:.3f} "
                  f"held {row['held']:.3f} (+s+off {row['held+scale+offset']:.3f})", flush=True)
    return rows


def run_llf():
    """Fit every LLF setting to the grating chart; then on the photographs' blocks, frames held out: each family's
    free-sign grating setting (not a valid remap, kept to show it overfits), its levels refitted on photographs, and
    its positive grating setting (a valid local Laplacian filter)."""
    gratings = llf_grating_fit()
    save("llf-gratings.json", gratings)
    rows = []
    for kind in LLF_FAMILIES:
        k = gratings[f"{kind} mixed widths, free signs"]["k"]
        c = Ceiling(PHOTOS, f"llf-{kind}", lambda b, gb, kind=kind, k=k: llf_photo_groups(b, gb, kind, k))
        rows += llf_rows(c, kind, LLF_MODELS)
        rows += llf_rows(setting_ceiling(kind, gratings[f"{kind} mixed widths"]["k"]), kind, POSITIVE_MODELS)
    save("llf-photos.json", rows)
    return gratings, rows


def step_profiles(d, chart="p-steps"):
    """Per bar, a change image's row mean over the bar's central half, folded at both edges at F1's offsets."""
    out = []
    for r, prof in F.bar_profiles(d, chart):
        a, b = (c - r["box"][0] for c in r["highColumns"])
        rising = np.array([prof[a + o] for o in F.STEP_OFFSETS])
        falling = np.array([prof[b - 1 - o] for o in F.STEP_OFFSETS])
        out.append((rising + falling) / 2)
    return np.array(out)


def run_steps(chart="p-steps", key="clarity+100"):
    """Halo test: Lightroom's folded edge profiles on the step chart against k D + c for F1's guided D and each LLF
    family's grating setting (k and c fitted over all bars), in stops; also each one's profile on the middle 3-stop
    bar."""
    m = json.loads((F1_OUT / "measure.json").read_text())["steps"][chart]
    target = np.array([r["profile"] for r in m[key]])
    bars = m["bars"]
    gratings = json.loads((OUT / "llf-gratings.json").read_text())
    Y = F.read_y(F.export_path(chart))
    g = np.log2(np.maximum(Y, 2.0 ** -16)).astype(np.float32)
    a, c = F.guided_coefficients(Y.astype(np.float64), 1024, 0.08, 1.0)
    del Y
    details = {"F1 guided D": (g - probe.ToneBase.sample(a, g.shape) * g - probe.ToneBase.sample(c, g.shape)).astype(np.float32)}
    for kind, widths in LLF_FAMILIES.items():
        k = gratings[f"{kind} mixed widths"]["k"]
        D = np.zeros_like(g)
        for i, w in enumerate(widths):
            E, shapes = llf_levels(g, kind, w, CHART_LEVELS)
            for l in range(CHART_LEVELS):
                D += np.float32(k[i * CHART_LEVELS + l]) * lift(E[l], shapes[:l])
            del E
        details[f"LLF {kind}, grating setting"] = D
    out = {"offsets": list(F.STEP_OFFSETS), "bars": bars, "lightroom": target.round(4).tolist()}
    for name, D in details.items():
        P = step_profiles(D, chart)
        A = np.stack([P.ravel(), np.ones(P.size)], axis=1)
        (kk, cc), *_ = np.linalg.lstsq(A, target.ravel(), rcond=None)
        model = kk * P + cc
        out[name] = {"k": float(kk), "c": float(cc), "rms": float(np.sqrt(np.mean((model - target) ** 2))),
                     "rms_per_bar": np.sqrt(np.mean((model - target) ** 2, axis=1)).round(3).tolist(),
                     "profile": model.round(4).tolist()}
        print(f"  steps {name:28s} k {kk:.3f} c {cc:+.3f} rms {out[name]['rms']:.3f} per bar {out[name]['rms_per_bar']}",
              flush=True)
    return out


EDGE_DISTANCES = (-1024, -512, -256, -128, -64, -32, -16, 16, 32, 64, 128, 256, 512, 1024)


def edge_gains(g0, gv, band, period, edge=2048):
    """A grating's gain |C_v / C_0| in windows of four periods centred at signed distances from the rising edge
    (negative on the dark side), on the band's central half of rows."""
    y0, y1 = band[1] + (band[3] - band[1]) // 4, band[3] - (band[3] - band[1]) // 4
    p0, pv = np.nanmean(g0[y0:y1], axis=0).astype(np.float64), np.nanmean(gv[y0:y1], axis=0).astype(np.float64)
    out = []
    for dist in EDGE_DISTANCES:
        c = edge + dist
        x = np.arange(c - 2 * period, c + 2 * period)
        out.append(abs(F.fundamental(pv[x], period, 0, x) / F.fundamental(p0[x], period, 0, x)))
    return np.array(out)


def run_edge(chart="q-edge", key="clarity+100"):
    """Gain against distance from a 3-stop edge for Lightroom, F1's guided D and each LLF family's positive grating
    setting. Each side is scored on its own: a model's strength there is set so its gain 1024 px from the edge matches
    Lightroom's on that side, and only windows that do not cross the edge count. The dark side is reported but not
    trusted: Clarity +100 moves its level 3 stops into Lightroom's toe, which changes display-log gains by itself."""
    lay = json.loads((R2_LAYOUTS / f"{chart}.json").read_text())
    bands = [r for r in lay["regions"] if r["kind"] == "bar grating"]
    Y = F.read_y(F.export_path(chart))
    g0 = np.log2(np.maximum(Y, 2.0 ** -16)).astype(np.float32)
    gv = F.log2y(F.read_y(F.export_path(chart, *F.split_key(key))))
    a, c = F.guided_coefficients(Y.astype(np.float64), 1024, 0.08, 1.0)
    del Y
    details = {"F1 guided D": (g0 - probe.ToneBase.sample(a, g0.shape) * g0 - probe.ToneBase.sample(c, g0.shape)).astype(np.float32)}
    gratings = json.loads((OUT / "llf-gratings.json").read_text())
    for kind, widths in LLF_FAMILIES.items():
        k = gratings[f"{kind} mixed widths"]["k"]
        D = np.zeros_like(g0)
        for i, w in enumerate(widths):
            E, shapes = llf_levels(g0, kind, w, CHART_LEVELS)
            for l in range(CHART_LEVELS):
                D += np.float32(k[i * CHART_LEVELS + l]) * lift(E[l], shapes[:l])
            del E
        details[f"LLF {kind}, positive grating setting"] = D
    dist = np.array(EDGE_DISTANCES)
    out = {"distances": list(EDGE_DISTANCES)}
    for band in bands:
        period = int(band["periodPx"])
        lr = edge_gains(g0, gv, band["box"], period)
        usable = np.abs(dist) >= 2 * period
        row = {"lightroom": lr.round(3).tolist(), "usable": usable.tolist()}
        print(f"  q-edge period {period}: Lightroom {dict(zip(EDGE_DISTANCES, lr.round(2)))}", flush=True)
        for name, D in details.items():
            unit = edge_gains(g0, g0 + D, band["box"], period)
            model = np.zeros_like(unit)
            for side in (dist < 0, dist > 0):
                far = np.flatnonzero(side & (np.abs(dist) == 1024))[0]
                k = (lr[far] - 1) / (unit[far] - 1)
                model[side] = 1 + k * (unit[side] - 1)
            near = usable & (dist > 0) & (dist <= 256)
            row[name] = {"gain": model.round(3).tolist(),
                         "bright_side_rms_within_256": round(float(np.sqrt(np.mean((model - lr)[near] ** 2))), 3)}
            print(f"     {name:36s} bright side, rms within 256 px {row[name]['bright_side_rms_within_256']:.3f}  "
                  f"gains {dict(zip(EDGE_DISTANCES, model.round(2)))}", flush=True)
        out[f"period {period}"] = row
    return out


def _gram_from_sources(job, path, make):
    b = lr_blocks(job)
    gb = np.log2(np.maximum(b["base"], 2.0 ** -16)).astype(np.float32)
    valid = np.all([valid_blocks(b, k) for k in CLARITY_KEYS], axis=0)
    rng = np.random.default_rng(sum(map(ord, job)))
    idx = np.flatnonzero(valid.ravel())
    idx = np.sort(rng.choice(idx, min(SAMPLES, idx.size), replace=False))
    cols, names, groups = [], [], []
    for source in (f1_detail_columns(b, gb), make(b, gb)):
        for group, name, image in source:
            cols.append(image.ravel()[idx].astype(np.float32))
            names.append(name)
            groups.append(group)
    X = np.stack(cols, axis=1)
    del cols
    out = {"names": np.array(names), "groups": np.array(groups), "n": idx.size, "XtX": gram(X, X)}
    for key in CLARITY_KEYS:
        y = (np.log2(np.maximum(b[key], 2.0 ** -16)) - gb).ravel()[idx].astype(np.float64)
        out[f"Xty {key}"] = gram(X, y[:, None])[:, 0]
        out[f"yty {key}"] = float(y @ y)
        out[f"sy {key}"] = float(y.sum())
    np.savez(path, **out)


# MARK: The outcome rule, fixed before the work: a new structure replaces F1's guided fields only with held-out block
# R2 of the positive side >= 0.75 in Lightroom's terms AND film rmse at +100 and +50 at least 10 % under F1's on the
# same held-out frames.

RULE_R2 = 0.75
BAR_MARGIN = 1.05


def run_rule():
    """The verdict from the saved scores: every structure's best held-out R2 against the bar, F1's held-out film scores
    on both rounds, and the pass bars proposed for the Swift build (held-out prototype score times BAR_MARGIN)."""
    both = json.loads((OUT / "ceiling-both-rounds.json").read_text())
    llf = json.loads((OUT / "llf-photos.json").read_text())
    candidates = []
    for r in both:
        candidates.append({"structure": r["model"], "value": r["value"], "held7": r["A held7"], "round2": r["A round2"],
                           "frames": "7 + 20"})
    for r in llf:
        candidates.append({"structure": f"LLF {r['family']}: {r['model']}", "value": r["value"], "held7": r["held"],
                           "round2": None, "frames": "7"})
    print("Rule, part 1: held-out block R2 of the positive side in Lightroom's terms (fit on F1's four frames)")
    for c in candidates:
        r2 = c["held7"] if c["round2"] is None else (7 * c["held7"] + 20 * c["round2"]) / 27
        c["held_all"] = r2
        c["passes"] = bool(r2 >= RULE_R2)
        print(f"  {c['structure']:66s} {c['value']:12s} held {r2:.3f} on {c['frames']:6s} frames  "
              f"{'meets 0.75' if c['passes'] else 'below 0.75'}")
    winners = [c for c in candidates if c["passes"]]
    verdict = ("a structure meets part 1; its film score decides" if winners else
               "no structure meets part 1, so none can replace F1's guided fields: keep F1's guided fields")
    print("Verdict:", verdict)
    rows1 = json.loads((OUT / "holdout-f1.json").read_text())
    path2 = OUT / "holdout-f1-round2.json"
    rows2 = json.loads(path2.read_text()) if path2.exists() else []
    bars = {}
    print("F1's constants through the film on held-out frames (mean per-block L* rmse, R2, floor; crop for Texture)")
    for name in ("clarity-guided", "texture-guided-band"):
        for v in VALUES:
            sel = [r for r in rows1 + rows2 if r["candidate"] == name and r["value"] == v]
            if not sel:
                continue
            metric = "crop_rmse" if name.startswith("texture") else "rmse"
            mean = float(np.mean([r[metric] for r in sel]))
            bars[f"{name} {v:+d}"] = {"metric": metric, "held_out": round(mean, 3), "bar": round(mean * BAR_MARGIN, 2),
                                      "runs": len(sel), "r2": round(float(np.mean([r["r2"] for r in sel])), 3),
                                      "floor": round(float(np.mean([r["floor"] for r in sel])), 3)}
            print(f"  {name:20s} {v:+4d} {metric:9s} {mean:5.2f}  r2 {bars[f'{name} {v:+d}']['r2']:+.3f}  floor "
                  f"{bars[f'{name} {v:+d}']['floor']:.2f}  runs {len(sel):3d}  proposed bar <= {mean * BAR_MARGIN:.2f}")
    return {"candidates": candidates, "verdict": verdict, "bars": bars}


def write_constants(rule):
    """constants.json: the recommendation with F1's constants copied unchanged, the split, every constant this round
    fitted (LLF strengths, the signal's slope, the adaptation fits), and the proposed held-out pass bars, each with the
    function and the file that made it."""
    f1 = f1_constants()
    gratings = json.loads((OUT / "llf-gratings.json").read_text())
    signal = json.loads((OUT / "signal-chart.json").read_text())
    adaptation = json.loads((OUT / "adaptation.json").read_text()) if (OUT / "adaptation.json").exists() else {}
    best_signal = min((r for r in signal["fits"]), key=lambda r: r["rms_log2_weight"])
    out = {
        "script": "scripts/lightroom-probe/fit_clarity_round2.py",
        "recommendation": {"clarity": "clarity-guided (F1), constants unchanged", "texture": "texture-guided-band (F1), "
                           "constants unchanged", "source": str(F1_OUT / "constants.json"),
                           "clarity-guided": {k: f1["clarity-guided"][k] for k in ("positive", "negative")},
                           "texture-guided-band": {k: f1["texture-guided-band"][k] for k in ("positive", "negative")}},
        "split": {"fit": list(FIT), "held_round1": list(HELD), "held_round2": list(ROUND2_PHOTOS),
                  "step5": {"fit": list(PHOTOS), "held": list(ROUND2_PHOTOS)}},
        "rule": {"r2_bar": RULE_R2, "film_improvement_bar": 0.10, "verdict": rule["verdict"]},
        "pass_bars_held_out": rule["bars"],
        "pass_bar_margin": BAR_MARGIN,
        "llf": {"made_by": "llf_grating_fit, llf-gratings.json", "families": {k: list(v) for k, v in LLF_FAMILIES.items()},
                "levels": CHART_LEVELS, "grid_step": "0.75 sigma",
                **{f"{kind} positive strengths [width][level]": np.array(gratings[f"{kind} mixed widths"]["k"])
                   .reshape(len(LLF_FAMILIES[kind]), CHART_LEVELS).round(4).tolist() for kind in LLF_FAMILIES},
                **{f"{kind} grating rms": round(gratings[f"{kind} mixed widths"]["rms"], 4) for kind in LLF_FAMILIES}},
        "signal": {"made_by": "run_signal_chart, signal-chart.json", "best": best_signal,
                   "law": "Clarity +100's weight per hue ~ (S / Y) ** slope, S the best signal"},
        "adaptation": {"made_by": "run_adaptation, adaptation.json",
                       "rows": [{k: r[k] for k in ("value", "statistic", "common", "predicted", "oracle", "rank_corr_round2",
                                                   "scale_fit", "offset_fit")} for r in adaptation.get("rows", [])]},
        "ceiling": {"made_by": "run_ceiling and run_both_rounds", "files": ["ceiling.json", "ceiling-global.json",
                    "ceiling-signal.json", "ceiling-both-rounds.json"], "ridge_lambdas": list(LAMBDAS),
                    "samples_per_frame": SAMPLES, "levels": LEVELS, "tone_knots": list(TONE_KNOTS),
                    "amplitude_knots": list(AMP_KNOTS), "relative_curve_knots": list(RELATIVE_CURVE_KNOTS),
                    "coarse_sigmas_blocks": list(COARSE_SIGMAS)},
    }
    save("constants.json", out)
    return out


def print_rows(lines):
    for r in lines:
        print("  ".join(f"{k} {v}" for k, v in r.items()), flush=True)


# MARK: A spike build (argent-spike with --clarity and --texture) against the held-out bars, under the explicit aim

SPIKE_CANDIDATES = {"clarity": "clarity-guided", "texture": "texture-guided-band"}
VALIDATION = EVIDENCE / "validate" / "detail"
BARS = VALIDATION / "bars.json"
RUNS = VALIDATION / "runs.json"
AIM = "aim"
# F1's flags less --auto: the explicit aim stands in for Auto, the rest is the scorecard's render.
AIM_TAIL = tuple(f for f in F.FLAGS if f != "--auto")
PARITY_MARGIN = 1.10
# Package C's caps (build/C/report.md section 7): a parity over them means more than the tone weights' transfer differs.
PARITY_CAPS = {("clarity", 100): 0.30}
PARITY_CAP = 0.20
REPLACED_WHY = ("rule.json's bars were the prototype's held-out scores under --auto. The prototype reaches the film "
                "through --scene-in, so Auto's tone step read its base from the prototype's changed scene, where the "
                "build's (and the app's) reads the untouched frame. They scored the prototype with a tone change the "
                "build never makes, so the bars were replaced by the prototype's scores under the explicit aim, where "
                "both read the same base (validate/detail/report.md).")


def aim_flags(job, stock, binary):
    """The flags that print `job` as F1's `--auto` does without Auto's tone step: `fit_dehaze.aim_flags` (the aim's
    level as the reference and Auto's lab balance, read from `binary`) and F1's other flags. Through --scene-in, Auto's
    tone step reads its base from the scene it is given, so it would read the prototype's changed scene where the build
    reads the untouched frame (fit-common fact 2). Without the step both prints read the same base."""
    return tuple(FD.aim_flags(raw_of(job), F.STOCKS / stock, binary)[0]) + AIM_TAIL


def held_frame(job, stock, flags):
    """F1's FilmFrame of a held-out photograph under `flags`, with its central 2048 crop, on Lightroom's export grid."""
    shape = export_shape(job)
    frame = F.FilmFrame(job, stock, flags, crop=F.central_crop(shape))
    if frame.Y.shape != shape:
        raise SystemExit(f"{job}: Argent's decode is {frame.Y.shape}, Lightroom's export {shape}")
    return frame


def bar_runs(slider, value):
    """The runs a held-out bar is the mean of: each held-out frame Lightroom rendered at this value, on each stock."""
    return {(job, stock) for job in HELD + ROUND2_PHOTOS if F.export_path(job, slider, value).exists()
            for stock in F.SCORE_STOCKS}


def build_print(binary, frame, *extra):
    """The build's own print of `frame` with its flags and `extra` (`--clarity`, 50), read as `FilmFrame.render` reads
    the prototype's: block L* and the central crop's L*."""
    with tempfile.TemporaryDirectory() as out:
        path = Path(out) / "print.npy"
        probe.spike(frame.raw, out, frame.stock_dir, *frame.flags, *extra, "--print-out", path, binary=binary)
        p = np.load(path)
    return F.print_lstar(p, frame.block), probe.lstar((p[frame.crop] @ F.PRINT_Y).astype(np.float64))


def fidelity(frame, key, prints, slider):
    """A print's change from the frame's base print against Lightroom's change at `key`: F1's per-block scores, and for
    Texture also the central crop's per pixel (`crop_*`)."""
    blocks, crop = prints
    out = F.scores(blocks - frame.L0, frame.lr_change(key), frame.valid)
    if slider == "texture":
        out.update({f"crop_{m}": x for m, x in F.scores(crop - frame.L0c, frame.lr_crop_change(key), frame.validc).items()})
    return out


def apart(a, b, slider):
    """Parity's metric: rms ΔL* of print `a` less print `b`, over the blocks for Clarity and over the crop's pixels for
    Texture. The build's base print is the prototype's bit for bit (`score_protocols` checks it), so this is also the
    rms of the two changes' difference."""
    i = 1 if slider == "texture" else 0
    return rms(a[i] - b[i])


def rms(x):
    return float(np.sqrt(np.mean(np.square(x))))


def score_spike(binary, frames=None, stocks=F.SCORE_STOCKS, sliders=tuple(SPIKE_CANDIDATES), parity=True, log=print):
    """Clarity and Texture through the build's own stages on the held-out frames under the explicit aim (`aim_flags`),
    scored as `run_holdout` scored the prototype: the build's change (its print with the flag less F1's base print, from
    the same build and flags) against Lightroom's in per-block ΔL* rmse, and for Texture also per pixel on the central
    2048 crop. With `parity` each run also prints F1's stage through the same build and flags: its scores are the
    prototype's (`prototype_*`, what the bars are made of), and `parity` is the build's print against it (`apart`).
    Returns one row per frame, stock, slider and value."""
    constants = f1_constants()
    runs = []
    # FilmFrame prints through F.SPIKE, so its base print and the prototype's come from the build under test.
    real, F.SPIKE = F.SPIKE, Path(binary)
    try:
        for job in frames or HELD + ROUND2_PHOTOS:
            for stock in stocks:
                t0 = time.time()
                frame = held_frame(job, stock, aim_flags(job, stock, binary))
                # F1 floors log luminance at 2^-20 where the build reads Argent's guide, log2 sqrt(Y^2 + 1e-12): on these
                # pixels negative Texture lifts the prototype's print by many stops and the build's by few.
                nonpositive = [int(np.count_nonzero(frame.Y <= 0)), int(np.count_nonzero(frame.Y[frame.crop] <= 0))]
                for slider in sliders:
                    c = constants[SPIKE_CANDIDATES[slider]]
                    metric = "crop_rmse" if slider == "texture" else "rmse"
                    details = {key: F.make_detail(c[key], frame.Y, frame.g) for key in ("positive", "negative")} \
                        if parity else {}
                    for v in VALUES:
                        key, side = f"{slider}{v:+d}", ("positive" if v > 0 else "negative")
                        if key not in frame.lr:
                            continue
                        build = build_print(binary, frame, f"--{slider}", v)
                        row = {"slider": slider, "job": job, "stock": stock, "value": v, "protocol": AIM,
                               **fidelity(frame, key, build, slider),
                               "floor": rms(frame.floor(key)[frame.valid]), "nonpositive": nonpositive}
                        if parity:
                            ours = frame.render(frame.delta(c[side], v, details[side]))
                            row.update({f"prototype_{m}": x for m, x in fidelity(frame, key, ours, slider).items()})
                            row["parity"] = apart(build, ours, slider)
                        runs.append(row)
                        log(f"  {slider:8s} {job:22s} {stock:17s} {v:+4d} {metric} {row[metric]:6.3f}"
                            + (f" prototype {row['prototype_' + metric]:6.3f} parity {row['parity']:.4f}"
                               if parity else ""))
                    del details
                del frame
                log(f"  {job} {stock}: {time.time() - t0:.0f} s")
    finally:
        F.SPIKE = real
    return runs


def judge_spike(runs, bars):
    """Each bar of `bars` (`spike_bars()`) against the build's runs: the mean of its fidelity metric against the bar,
    and the mean parity against the bar's parity limit (none set, no verdict). A bar is a mean over its runs, so it is
    judged only when every run behind it was scored; a subset's mean is reported with no verdict. A bar judges only
    runs made under its own protocol, so rule.json's bars, set under --auto, refuse the explicit aim's runs."""
    rows = []
    for slider, name in SPIKE_CANDIDATES.items():
        for v in VALUES:
            sel = [r for r in runs if r["slider"] == slider and r["value"] == v]
            bar = bars.get(f"{name} {v:+d}")
            if not sel or bar is None:
                continue
            made = {r.get("protocol") for r in sel}
            if made != {bar.get("protocol")}:
                raise SystemExit(f"{name} {v:+d}: the bar was set under {bar.get('protocol') or '--auto'} and the runs "
                                 f"were made under {', '.join(sorted(p or '--auto' for p in made))}. Judge the explicit "
                                 f"aim's runs against {BARS} (fit_clarity_round2.spike_bars()).")
            m = float(np.mean([r[bar["metric"]] for r in sel]))
            complete = {(r["job"], r["stock"]) for r in sel} == bar_runs(slider, v)
            rows.append({"bar": f"{slider} {v:+d}, mean {bar['metric']}", "stock": "both", "measured": m,
                         "max": bar["bar"], "prototype": bar["held_out"], "runs": len(sel),
                         "pass": m <= bar["bar"] if complete else None,
                         "note": f"prototype {bar['held_out']:.3f}, {len(sel)} runs"})
            gaps = [r["parity"] for r in sel if "parity" in r]
            if gaps:
                where = "crop" if slider == "texture" else "blocks"
                limit = bar.get("parity", {}).get("max")
                mean, worst = float(np.mean(gaps)), float(np.max(gaps))
                rows.append({"bar": f"{slider} {v:+d}, parity: rms ΔL* over the {where} against the prototype's change",
                             "stock": "both", "measured": mean, "worst": worst, "max": limit, "runs": len(gaps),
                             "pass": mean <= limit if complete and limit is not None else None,
                             "note": f"worst run {worst:.3f}, {len(gaps)} runs" + ("" if limit is not None else
                                                                                    "; no limit set")})
    return rows


def spike_bars(path=BARS):
    """The held-out bars `judge_spike` reads, by "<candidate> <value>": bars.json's, set under the explicit aim."""
    return json.loads(Path(path).read_text())["bars"]


def parity_limit(slider, value, mean):
    """validate/detail/preregistration.md section 2: the build's mean parity times PARITY_MARGIN, never above the cap;
    None (no limit) when the mean itself is over the cap."""
    cap = PARITY_CAPS.get((slider, value), PARITY_CAP)
    return min(round(mean * PARITY_MARGIN, 3), cap) if mean <= cap else None


def make_bars(runs, binary):
    """bars.json from a full `score_spike` run with parity, by validate/detail/preregistration.md section 2: each bar the
    prototype's held-out mean under the explicit aim times BAR_MARGIN, each parity limit `parity_limit` of the build's
    mean parity. A bar needs every run Lightroom rendered at its value. rule.json's bars are kept under "replaced"."""
    bars = {}
    for slider, name in SPIKE_CANDIDATES.items():
        metric = "crop_rmse" if slider == "texture" else "rmse"
        for v in VALUES:
            sel = [r for r in runs if r["slider"] == slider and r["value"] == v and "parity" in r]
            if {(r["job"], r["stock"]) for r in sel} != bar_runs(slider, v) or {r.get("protocol") for r in sel} != {AIM}:
                raise SystemExit(f"{slider} {v:+d}: {len(sel)} runs with parity under the aim, a bar needs all "
                                 f"{len(bar_runs(slider, v))}")
            held = float(np.mean([r[f"prototype_{metric}"] for r in sel]))
            mean, worst = float(np.mean([r["parity"] for r in sel])), max(sel, key=lambda r: r["parity"])
            bars[f"{name} {v:+d}"] = {
                "protocol": AIM, "metric": metric, "held_out": round(held, 3), "bar": round(held * BAR_MARGIN, 2),
                "runs": len(sel), "r2": round(float(np.mean([r["prototype_r2"] for r in sel])), 3),
                "floor": round(float(np.mean([r["floor"] for r in sel])), 3),
                "parity": {"measured": round(mean, 4), "worst": round(worst["parity"], 4),
                           "worstRun": f"{worst['job']} {worst['stock']}",
                           "cap": PARITY_CAPS.get((slider, v), PARITY_CAP), "max": parity_limit(slider, v, mean)}}
    return {
        "made": time.strftime("%Y-%m-%d %H:%M"), "script": "scripts/lightroom-probe/fit_clarity_round2.py spike-bars",
        "binary": str(binary), "binarySha256": sha256(binary),
        "protocol": {
            "name": AIM, "flags": "fit_dehaze.aim_flags(raw, stock, binary) + " + " ".join(map(str, AIM_TAIL)),
            "aim": "--reference-stops at Auto's aim level and --lab-balance at Auto's balance, read from the binary's "
                   "own --auto render at --scale 0.25; no tone step",
            "frames": list(HELD + ROUND2_PHOTOS), "stocks": list(F.SCORE_STOCKS),
            "prototype": "F1's clarity-guided and texture-guided-band, constants unchanged "
                         f"({F1_OUT / 'constants.json'}), the tone weight through each frame's fitted transfer under "
                         "the same flags (FilmFrame.T), printed through --scene-in by the same binary",
            "fidelity": "the change (print with the flag less the base print) against Lightroom's from its own base: "
                        "per 4 x 4 block L* rmse over blocks whose bases lie in (0.5, 99.5) for Clarity (rmse), per "
                        "pixel over the central 2048 crop for Texture (crop_rmse); mean over the runs",
            "parity": "rms ΔL* of the build's print less the prototype's over the blocks (Clarity) or the crop's "
                      "pixels (Texture), each run; mean over the runs"},
        "rules": {"bar": f"the prototype's held-out mean times {BAR_MARGIN}, 2 decimals",
                  "parity": f"the build's mean parity times {PARITY_MARGIN}, 3 decimals, never above the cap; not set "
                            "when the mean is over the cap",
                  "caps": {"clarity +100": PARITY_CAPS[("clarity", 100)], "every other value": PARITY_CAP},
                  "preregistration": str(VALIDATION / "preregistration.md")},
        "bars": bars,
        "replaced": {"source": str(OUT / "rule.json"), "why": REPLACED_WHY,
                     "bars": json.loads((OUT / "rule.json").read_text())["bars"]}}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""):
            h.update(chunk)
    return h.hexdigest()


def save_runs(path, runs, binary):
    Path(path).write_text(json.dumps({"made": time.strftime("%Y-%m-%d %H:%M"), "binary": str(binary),
                                      "binarySha256": sha256(binary), "runs": runs}, indent=0))


def kept_runs(path=RUNS):
    """The prototype's held-out runs under the explicit aim that bars.json was made from, by (slider, job, stock,
    value), each holding the prototype's scores under the fidelity metrics' own names (`rmse`, `crop_rmse`)."""
    rows = json.loads(Path(path).read_text())["runs"]
    return {(r["slider"], r["job"], r["stock"], r["value"]):
            {k.removeprefix("prototype_"): x for k, x in r.items() if k.startswith("prototype_")} for r in rows}


# MARK: The hypothesis test: which protocol, and which transfer, the parity is made of

class NeutralTransfer:
    """The stock's own transfer from scene stops (log2 over 0.18) to print L*, read off a grey ramp the binary prints
    under the frame's flags: what the build's tone weights read (`PresenceToneWeights`, through
    `ManualToneTables.Transfer`), where the prototype reads each frame's fitted transfer (`FilmFrame.T`). Package C's
    `neutral_transfer` (build/C/score_detail_spike.py)."""

    def __init__(self, frame):
        h, w = frame.Y.shape
        self.stops = np.linspace(-14, 8, w)
        ramp = np.ascontiguousarray(np.broadcast_to((0.18 * np.exp2(self.stops)).astype(np.float32)[None, :, None],
                                                    (h, w, 3)))
        p = scene_io.print_of(frame.raw, frame.stock_dir, ramp, *frame.flags, binary=F.SPIKE)
        del ramp
        self.lstar = np.maximum.accumulate(probe.lstar((p[h // 4:3 * h // 4] @ F.PRINT_Y).mean(axis=0)
                                                       .astype(np.float64)))

    def __call__(self, x):
        return np.interp(x, self.stops, self.lstar)


PROTOCOL_PARTS = ("auto", AIM, "aim neutral", "auto neutral", "transfer")
PREDICTION_REST = 0.05


def score_protocols(binary, frames, stocks=F.SCORE_STOCKS, log=print):
    """validate/detail/preregistration.md section 1, on each run: parity under --auto (`auto`, the quick scorecard's) and
    under the explicit aim (`aim`), each also against the prototype reading the stock's neutral transfer as the build
    does (`auto neutral`, `aim neutral`; the aim's ramp for both, since the build's weights never read Auto's tone
    step), the transfer's own part under the aim (`transfer`: the prototype with its fitted transfer against it with
    the neutral one), and the rms change of the build's print and of the prototype's. Per frame and stock also the
    build's base print against the prototype's (`base`: rms L* over the blocks and over the crop) and one base print
    rendered twice (`repeat`: values that differ). Returns (runs, frame checks)."""
    constants = f1_constants()
    rows, checks = [], []
    real, F.SPIKE = F.SPIKE, Path(binary)
    try:
        for job in frames:
            for stock in stocks:
                t0 = time.time()
                aim = aim_flags(job, stock, binary)
                per, check = {}, {"job": job, "stock": stock, "aimFlags": [str(f) for f in aim]}
                for protocol, flags in ((AIM, aim), ("auto", F.FLAGS)):
                    frame = held_frame(job, stock, flags)
                    if protocol == AIM:
                        neutral = NeutralTransfer(frame)
                    base = build_print(binary, frame)
                    check[f"{protocol} base"] = [rms(base[0] - frame.L0), rms(base[1] - frame.L0c)]
                    if protocol == AIM:
                        again = build_print(binary, frame)
                        check["repeat"] = int(np.count_nonzero(again[0] != base[0]) + np.count_nonzero(again[1] != base[1]))
                    fitted = frame.T
                    for slider, name in SPIKE_CANDIDATES.items():
                        c, i = constants[name], (1 if slider == "texture" else 0)
                        details = {k: F.make_detail(c[k], frame.Y, frame.g) for k in ("positive", "negative")}
                        for v in VALUES:
                            key, side = f"{slider}{v:+d}", ("positive" if v > 0 else "negative")
                            if key not in frame.lr:
                                continue
                            build = build_print(binary, frame, f"--{slider}", v)
                            frame.T = fitted
                            own = frame.render(frame.delta(c[side], v, details[side]))
                            frame.T = neutral
                            plain = frame.render(frame.delta(c[side], v, details[side]))
                            frame.T = fitted
                            row = per.setdefault((slider, v), {"slider": slider, "job": job, "stock": stock, "value": v})
                            row[protocol] = apart(build, own, slider)
                            row[f"{protocol} neutral"] = apart(build, plain, slider)
                            row[f"{protocol} change"] = [rms(build[i] - base[i]), rms(own[i] - base[i])]
                            if protocol == AIM:
                                row["transfer"] = apart(own, plain, slider)
                            log(f"  {protocol:4s} {slider:7s} {job:16s} {stock:17s} {v:+4d} parity {row[protocol]:.4f}"
                                f" against the neutral transfer {row[f'{protocol} neutral']:.4f}"
                                + (f" transfer {row['transfer']:.4f}" if protocol == AIM else "")
                                + f" change {row[f'{protocol} change'][0]:.2f} / {row[f'{protocol} change'][1]:.2f}")
                        del details
                    del frame
                rows += per.values()
                checks.append(check)
                log(f"  {job} {stock}: {time.time() - t0:.0f} s, base apart {check['aim base']} (aim) "
                    f"{check['auto base']} (auto), repeat differs at {check['repeat']} values")
    finally:
        F.SPIKE = real
    return rows, checks


def protocol_verdict(rows):
    """validate/detail/preregistration.md section 1's decision on the means per control and value, with P the transfer
    part plus PREDICTION_REST: confirmed if aim <= P everywhere and aim <= auto / 2 at Clarity -100 and +100; refuted if
    aim > 2 P anywhere or aim > auto / 2 at Clarity +100; partly confirmed otherwise. Returns (verdict, table)."""
    table = []
    for slider in SPIKE_CANDIDATES:
        for v in VALUES:
            sel = [r for r in rows if r["slider"] == slider and r["value"] == v]
            if not sel:
                continue
            mean = {k: float(np.mean([r[k] for r in sel])) for k in PROTOCOL_PARTS}
            predicted = mean["transfer"] + PREDICTION_REST
            table.append({"slider": slider, "value": v, "runs": len(sel), "mean": mean,
                          "worst": {k: float(np.max([r[k] for r in sel])) for k in PROTOCOL_PARTS},
                          "predicted": predicted, "within": mean[AIM] <= predicted, "over": mean[AIM] > 2 * predicted,
                          "halved": mean[AIM] <= mean["auto"] / 2})
    clarity = [t for t in table if t["slider"] == "clarity" and abs(t["value"]) == 100]
    if any(t["over"] for t in table) or any(not t["halved"] for t in clarity if t["value"] == 100):
        return "refuted", table
    if all(t["within"] for t in table) and all(t["halved"] for t in clarity):
        return "confirmed", table
    return "partly confirmed", table


def command_protocols(binary, frames, stocks, out, log):
    rows, checks = score_protocols(binary, frames, stocks, log)
    verdict, table = protocol_verdict(rows)
    if out:
        Path(out).write_text(json.dumps({"made": time.strftime("%Y-%m-%d %H:%M"), "binary": str(binary),
                                         "binarySha256": sha256(binary), "verdict": verdict, "table": table,
                                         "frames": checks, "runs": rows}, indent=0))
    log("")
    log("| Control | Value | Runs | A: --auto | B: aim | C: aim, neutral transfer | D: --auto, neutral transfer | "
        "T: transfer | P = T + 0.05 | B worst | B <= P | B <= A / 2 |")
    log("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |")
    for t in table:
        m = t["mean"]
        log(f"| {t['slider']} | {t['value']:+d} | {t['runs']} | {m['auto']:.3f} | {m[AIM]:.3f} | {m['aim neutral']:.3f} | "
            f"{m['auto neutral']:.3f} | {m['transfer']:.3f} | {t['predicted']:.3f} | {t['worst'][AIM]:.3f} | "
            f"{'yes' if t['within'] else 'no'} | {'yes' if t['halved'] else 'no'} |")
    log("")
    log(f"The hypothesis is {verdict}.")
    return 0


# MARK: A stand-in build: F1's prototype behind the flags

def spike_flags_of(args):
    """The flags of a spike command line as `probe.spike` makes it, without what it and `scene_io` add again: the raw,
    --stock, --out, --no-warmup and --print-out."""
    flags, rest = [], iter(args[1:])
    for a in rest:
        if a in ("--stock", "--out", "--print-out"):
            next(rest)
        elif a != "--no-warmup":
            flags.append(a)
    return flags


def emulate_spike(argv):
    """A stand-in for a spike that has Clarity's and Texture's stages, made of today's spike (F.SPIKE) and F1's
    prototype: --clarity V or --texture V decodes with --scene-out, applies F1's stage as `FilmFrame.delta` does, its
    tone weight read through the frame's own transfer from scene stops to its base print's L*, and prints the result
    through --scene-in with the same flags. Its prints are the prototype's, so its held-out scores are the prototype's
    and its parity is 0."""
    args, slider, value = list(argv), None, 0.0
    for name in SPIKE_CANDIDATES:
        if f"--{name}" in args:
            i = args.index(f"--{name}")
            slider, value = name, float(args[i + 1])
            del args[i:i + 2]
    if value == 0 or "--help" in args:
        return subprocess.run([str(F.SPIKE), *args]).returncode
    raw, stock, flags = args[0], args[args.index("--stock") + 1], spike_flags_of(args)
    scene = scene_io.scene_of(raw, stock, *flags, binary=F.SPIKE)
    Y = scene @ F.REC2020_Y
    g = np.log2(np.maximum(Y, 2.0 ** -20)).astype(np.float32)
    L0 = F.print_lstar(scene_io.print_of(raw, stock, scene, *flags, binary=F.SPIKE))
    x = np.log2(np.maximum(probe.block_mean(Y).astype(np.float64), 2.0 ** -20) / 0.18)
    ok = (L0 > 0.3) & (L0 < 99.0)
    T = probe.Transfer(x[ok], L0[ok])
    side = f1_constants()[SPIKE_CANDIDATES[slider]]["positive" if value > 0 else "negative"]
    D, base = F.make_detail(side, Y, g)
    del Y, g
    Lb = T(np.log2(np.maximum(np.exp2(base), 2.0 ** -20) / 0.18))
    delta = (F.strength(side, value) * F.weight_at(side, Lb) * D).astype(np.float32)
    del D, base, Lb
    with tempfile.TemporaryDirectory() as tmp:
        np.save(f"{tmp}/scene.npy", np.ascontiguousarray(scene * np.exp2(delta)[..., None], dtype=np.float32))
        del scene, delta
        return subprocess.run([str(F.SPIKE), *args, "--scene-in", f"{tmp}/scene.npy"]).returncode


def stand_in_spike(folder):
    """A launcher for `emulate_spike`, which a scorer runs as it runs argent-spike."""
    launcher = Path(folder) / "argent-spike"
    launcher.write_text(f"#!/bin/sh\nexec {sys.executable} -I {Path(__file__).resolve()} emulate-spike \"$@\"\n")
    launcher.chmod(0o755)
    return launcher


# MARK: The commands

def judged_table(rows, log):
    log("| Bar | Runs | Measured | Allowed | Prototype | Result | Note |")
    log("| --- | ---: | ---: | ---: | ---: | --- | --- |")
    for r in rows:
        result = "pending" if r["max"] is None else "subset" if r["pass"] is None else "pass" if r["pass"] else "FAIL"
        allowed = "-" if r["max"] is None else f"{r['max']:.3f}"
        prototype = f"{r['prototype']:.3f}" if "prototype" in r else "-"
        log(f"| {r['bar']} | {r['runs']} | {r['measured']:.3f} | {allowed} | {prototype} | {result} | {r['note']} |")


def command_spike(argv):
    """`spike`: the build against bars.json, exit 1 on a failed bar, 3 when there are no bars yet. `spike-bars`:
    bars.json from a full `spike --runs` run, then those runs judged. `spike-check`: `spike` on a stand-in build of the
    prototype, whose runs must also equal the prototype's kept runs (runs.json) to 1e-6 with parity 0, exit 1 if not.
    `spike-protocols`: the hypothesis test's parity parts on `--frames`."""
    parser = argparse.ArgumentParser(prog="fit_clarity_round2.py")
    parser.add_argument("command", choices=["spike", "spike-bars", "spike-check", "spike-protocols"])
    parser.add_argument("--binary", default=str(F.SPIKE), help="the argent-spike to score")
    parser.add_argument("--frames", nargs="*", help="only these held-out frames (default: all 27)")
    parser.add_argument("--stocks", nargs="*", default=list(F.SCORE_STOCKS))
    parser.add_argument("--slider", action="append", choices=list(SPIKE_CANDIDATES), help="only this slider")
    parser.add_argument("--no-parity", action="store_true", help="skip the prototype's prints")
    parser.add_argument("--scratch", help="where Lightroom's blocks are cached (default: this round's scratch folder)")
    parser.add_argument("--runs", help="spike: save the runs here; spike-bars: make the bars from these saved runs")
    parser.add_argument("--out", help="spike-protocols: save its runs and table here")
    args = parser.parse_args(argv)
    global SCRATCH
    SCRATCH = Path(args.scratch) if args.scratch else SCRATCH
    SCRATCH.mkdir(parents=True, exist_ok=True)
    log = lambda *a: print(*a, flush=True)  # noqa: E731
    if args.command == "spike-protocols":
        if not args.frames:
            parser.error("spike-protocols needs --frames")
        return command_protocols(Path(args.binary), args.frames, args.stocks, args.out, log)
    if args.command == "spike-bars":
        saved = json.loads(Path(args.runs).read_text())
        runs = saved["runs"]
        BARS.write_text(json.dumps(make_bars(runs, Path(saved["binary"])), indent=1))
        log(f"Wrote {BARS}")
    else:
        frames = args.frames or (["p-photo-hazy"] if args.command == "spike-check" else None)
        with tempfile.TemporaryDirectory() as tmp:
            binary = stand_in_spike(tmp) if args.command == "spike-check" else Path(args.binary)
            runs = score_spike(binary, frames, args.stocks, tuple(args.slider or SPIKE_CANDIDATES), not args.no_parity,
                               log)
        if args.runs:
            save_runs(args.runs, runs, F.SPIKE if args.command == "spike-check" else binary)
    if not BARS.exists():
        log(f"No bars yet at {BARS}: make them with spike-bars --runs FILE from a full spike --runs FILE run.")
        return 3
    rows = judge_spike(runs, spike_bars())
    log("")
    judged_table(rows, log)
    failed = [r for r in rows if r["pass"] is False]
    if args.command == "spike-check":
        kept = kept_runs()
        for r in runs:
            want = kept[(r["slider"], r["job"], r["stock"], r["value"])]
            metric = "crop_rmse" if r["slider"] == "texture" else "rmse"
            ok = abs(r[metric] - want[metric]) <= 1e-6 and r.get("parity", 0.0) == 0.0
            failed += [] if ok else [r]
            log(f"  {'same' if ok else 'DIFFERS'} {r['slider']} {r['job']} {r['stock']} {r['value']:+d}: {metric} "
                f"{r[metric]:.6f} against the kept {want[metric]:.6f}, parity {r.get('parity', float('nan')):.6f}")
    log("")
    log(f"{'FAIL' if failed else 'PASS'}: {len(failed)} failed")
    return 1 if failed else 0


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "all"
    if command == "emulate-spike":
        sys.exit(emulate_spike(sys.argv[2:]))
    if command in ("spike", "spike-bars", "spike-check", "spike-protocols"):
        sys.exit(command_spike(sys.argv[1:]))
    OUT.mkdir(parents=True, exist_ok=True)
    SCRATCH.mkdir(parents=True, exist_ok=True)
    if command in ("holdout", "all"):
        run_holdout()
        if ROUND2_PHOTOS:
            run_holdout(ROUND2_PHOTOS, out_name="holdout-f1-round2.json")
        table = holdout_table()
        save("holdout-f1-table.json", table)
        print_rows(table)
    if command in ("ceiling", "all"):
        split = {}
        for job in PHOTOS:
            split[job] = change_split(job)
            for key, v in split[job].items():
                print(f"  {job:18s} {key:13s} mean {v['mean_stops']:+.3f} st {v['mean_lstar']:+.2f} L*  sd "
                      f"{v['sd_stops']:.3f}  tone-curve R2 {v['tone_curve_r2']:.3f}  finer than level 1..10 "
                      f"{v['finer_than_level']}", flush=True)
        save("change-split.json", split)
        save("ceiling.json", run_ceiling())
        save("ceiling-global.json", run_ceiling("global"))
        save("ceiling-signal.json", run_ceiling("signal", keys=("clarity+50", "clarity+100")))
    if command in ("signal", "all"):
        save("signal-chart.json", run_signal_chart())
    if command in ("rounds", "all") and ROUND2_PHOTOS:
        save("ceiling-both-rounds.json", run_both_rounds())
        save("adaptation.json", run_adaptation())
        save("adaptation-lofo.json", run_adaptation_lofo())
    if command in ("tone", "all") and ROUND2.exists():
        save("tone-charts.json", run_tone_charts())
    if command in ("llf", "all"):
        run_llf()
        save("llf-steps.json", run_steps())
        if ROUND2.exists():
            save("llf-edge.json", run_edge())
    if command in ("rule", "all"):
        rule = run_rule()
        save("rule.json", rule)
        write_constants(rule)


if __name__ == "__main__":
    main()
