#!/usr/bin/env python3
"""Fit each stock's exposure matrix, scene Rec. 2020 to layer exposure, to measured reflectances.

The Negative LUT sees a colour, not a spectrum, so the film's layer exposures have to be guessed from
RGB. The first bake used a smooth three-spectrum basis (`negative.reflectance_basis`); against measured
spectra it gave the print 0.84 of the true print's chroma on a ColorChecker, 0.76 on natural objects
and 0.57 on skin (docs/research/film-sim/compare.md section 4.6), because real yellows, reds and skins
are step-like spectra a smooth basis cannot follow. This fits the 3 by 3 matrix itself instead.

Data (both permitted, `docs/provenance.md`):
- Morimoto, Zhang, Fukuda and Uchikawa, "Spectral dataset of daylights and surface properties of
  natural objects measured in Japan", Zenodo 5217752, v1.2, CC BY 4.0: the 307 reflectances the
  authors used in their analysis (column "Used in analysis" TRUE; near-duplicates removed by them).
  Not in the repository; download Reflectance_v1-2.csv and pass its path.
- NIST's Reference Data Set of Human Skin Reflectance (Cooksey, Allen and Tsai 2017), 100 forearms,
  public domain, read from references/ as `skin_locus.load_nist` does.

Each reflectance is lit by D55, the film's reference daylight. Its true layer exposure is the
spectrum through the stock's sensitivities, relative to an 18 percent gray's. Its colour is what a
D55-pinned decode gives (XYZ under D55, adapted to D65, linear Rec. 2020, a D55 gray of 0.18 at 0.18;
`skin_locus.decode_rgb`). The matrix maps that colour, over 0.18, to relative layer exposure.

Objective: least squares on log10 exposure, every layer of every sample, the two sets weighted
equally (each sample's squared error divided by its set's size). Constraint: each row sums to one,
so equal RGB gives equal relative exposures, and every gray stays neutral at every level. Below
2^-10 of mid-gray, where the bake floors exposure, the log's tangent carries on, so a prediction at
or below zero, impossible for a real reflectance, is penalized rather than ignored. Solved per row (a layer's error depends on its row alone) by Gauss-Newton from the old
basis's matrix. Held-out error: four folds, each set split at random (seed 0) into quarters; each
quarter predicted by the fit to the other three. The shipped matrix is the fit to all of both sets.

    cd bake && PYTHONPATH=. ../.venv/bin/python tools/fit_exposure_matrix.py PATH/Reflectance_v1-2.csv [--write]

The shipped matrices are regularized (package G, docs/research/film-sim/matrix.md): each stock's fit takes the
row-length cap or ridge `REGULARIZATION` names, chosen by a criterion stated before any candidate ran. `fit` is the
plain least-squares fit, A2's, which the criterion compares against.

--write puts each matrix into its profile's "exposureMatrix" section.
"""

import argparse
import csv
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from skin_locus import decode_rgb, load_nist  # noqa: E402

from argent_bake.negative import REFERENCE_ILLUMINANT as D55, MID_GRAY, smooth_basis_matrix  # noqa: E402
from argent_bake.profile import load_profile  # noqa: E402

BAKE = Path(__file__).resolve().parents[1]
STOCKS = BAKE / "stocks"
NIST = BAKE.parent / "references/auto-printing/nist-skin-reflectance/skinrefl_v3.txt"
NAMES = ("portra400", "portra160", "portra800", "ektar100", "gold200", "ultramax400")
FLOOR = 2.0 ** -10  # the bake's RELATIVE_FLOOR
FOLDS = 4
SEED = 0
GRAY = np.full(D55.size, MID_GRAY)


def load_japan(path) -> np.ndarray:
    """The reflectances Morimoto et al. used in their analysis, (307, 81) on 380 to 780 nm by 5 nm."""
    rows = list(csv.reader(open(path, encoding="utf-8-sig")))
    return np.array([[float(v) for v in r[4:85]] for r in rows[1:] if r[2].strip().upper() == "TRUE"])


def samples(profile, reflectance: np.ndarray):
    """(decoded colour over mid-gray, true layer exposure over mid-gray's) for reflectances (n, 81)."""
    reflectance = np.clip(reflectance, 0.0, None)
    sens = profile.sensitivity
    exposure = ((reflectance * D55) @ sens) / ((GRAY * D55) @ sens)
    return decode_rgb(reflectance) / MID_GRAY, exposure


def log_floored(pred: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """log10 of a predicted exposure and its derivative; below FLOOR the log's tangent carries on, so a
    prediction at or below zero (impossible for a real reflectance) costs more the further it goes."""
    p = np.maximum(pred, FLOOR)
    value = np.where(pred > FLOOR, np.log10(p), np.log10(FLOOR) + (pred - FLOOR) / (FLOOR * np.log(10.0)))
    return value, 1.0 / (p * np.log(10.0))


def fit_rows(rgb: np.ndarray, exposure: np.ndarray, weights: np.ndarray, start: np.ndarray, ridge: float = 0.0,
             toward: np.ndarray | None = None, cap: float | None = None) -> np.ndarray:
    """The rows-sum-to-one matrix minimizing weighted squared log10 exposure error, by Gauss-Newton.

    `ridge` adds ridge * |row - toward's row|^2 to each row's cost (package G's candidates: toward the smooth basis
    or the identity). `cap` bounds each row's length: a row longer than it is refitted with a ridge toward zero,
    its strength found by bisection so the length comes out at the cap."""
    target = np.log10(np.maximum(exposure, FLOOR))
    toward = np.zeros((3, 3)) if toward is None else np.asarray(toward, dtype=float)
    matrix = np.array(start, dtype=float)
    base, d = rgb[:, 2], rgb[:, :2] - rgb[:, 2:3]
    lift = np.array([[1.0, 0.0], [0.0, 1.0], [-1.0, -1.0]])  # d row / d (a, b)

    def solve_row(j, lam, ref, v):
        # row = (a, b, 1 - a - b): prediction = blue + a (red - blue) + b (green - blue)
        def row(trial):
            return np.array([trial[0], trial[1], 1.0 - trial.sum()])

        def cost(trial):
            return float(weights @ (log_floored(base + d @ trial)[0] - target[:, j]) ** 2 + lam * np.sum((row(trial) - ref) ** 2))

        for _ in range(200):
            value, slope = log_floored(base + d @ v)
            r = value - target[:, j]
            jac = d * slope[:, None]
            normal = jac.T @ (weights[:, None] * jac) + lam * lift.T @ lift + 1e-12 * np.eye(2)
            step = np.linalg.solve(normal, -(jac.T @ (weights * r) + lam * lift.T @ (row(v) - ref)))
            old = cost(v)
            for _ in range(40):  # halve the step until the error falls
                if cost(v + step) <= old:
                    break
                step = step / 2
            v = v + step
            if np.abs(step).max() < 1e-10:
                break
        return v

    for j in range(3):
        v = solve_row(j, ridge, toward[j], matrix[j, :2].copy())
        if cap is not None and np.linalg.norm([v[0], v[1], 1.0 - v.sum()]) > cap:
            def length(lam):
                w = solve_row(j, lam, np.zeros(3), v.copy())
                return np.linalg.norm([w[0], w[1], 1.0 - w.sum()]), w

            lo, hi = 0.0, 1e-3
            while length(hi)[0] > cap:
                lo, hi = hi, hi * 4
            for _ in range(50):
                mid = (lo + hi) / 2
                if length(mid)[0] > cap:
                    lo = mid
                else:
                    hi = mid
            v = length(hi)[1]
        matrix[j] = [v[0], v[1], 1.0 - v.sum()]
    return matrix


# Package G (docs/research/film-sim/matrix.md section 3): each stock's regularization, chosen by the criterion committed
# before any candidate ran (expected print ΔE2000 under a permitted input-error model; within one JND of the
# unregularized fit's held-out error; ties within 0.05 broken toward the smooth basis).
REGULARIZATION = {
    "portra400": ("row cap", 1.7),
    "portra160": ("ridge to smooth", 0.01),
    "portra800": ("ridge to identity", 0.003),
    "ektar100": ("row cap", 1.8),
    "gold200": ("ridge to smooth", 0.003),
    "ultramax400": ("ridge to smooth", 0.003),
}


def fit_regularized(profile, sets: dict, family: str, strength: float) -> np.ndarray:
    """The fit with one of package G's regularizations: "row cap", "ridge to smooth", "ridge to identity"."""
    data = [samples(profile, r) for r in sets.values()]
    rgb = np.vstack([d[0] for d in data])
    exposure = np.vstack([d[1] for d in data])
    weights = set_weights([len(d[0]) for d in data])
    start = smooth_basis_matrix(profile)
    if family == "row cap":
        return fit_rows(rgb, exposure, weights, start, cap=strength)
    toward = {"ridge to smooth": start, "ridge to identity": np.eye(3)}[family]
    return fit_rows(rgb, exposure, weights, start, ridge=strength, toward=toward)


def set_weights(sizes) -> np.ndarray:
    return np.concatenate([np.full(n, 1.0 / n) for n in sizes])


def fit(profile, sets: dict) -> np.ndarray:
    data = [samples(profile, r) for r in sets.values()]
    rgb = np.vstack([d[0] for d in data])
    exposure = np.vstack([d[1] for d in data])
    return fit_rows(rgb, exposure, set_weights([len(d[0]) for d in data]), smooth_basis_matrix(profile))


def folds(sets: dict, k: int = FOLDS, seed: int = SEED):
    """For each fold, (training sets, held-out sets) with every set split into k random parts."""
    rng = np.random.default_rng(seed)
    parts = {name: np.array_split(rng.permutation(len(r)), k) for name, r in sets.items()}
    for i in range(k):
        train = {n: sets[n][np.concatenate([p for j, p in enumerate(parts[n]) if j != i])] for n in sets}
        held = {n: sets[n][parts[n][i]] for n in sets}
        yield train, held


def permitted_sets(japan_csv) -> dict:
    return {"natural objects (Morimoto et al., CC BY 4.0)": load_japan(japan_csv), "NIST forearms": load_nist(NIST)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("japan_csv")
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    sets = permitted_sets(args.japan_csv)
    print({n: len(r) for n, r in sets.items()})
    for name in NAMES:
        path = STOCKS / f"{name}.json"
        profile = load_profile(path)
        family, strength = REGULARIZATION[name]
        matrix = fit_regularized(profile, sets, family, strength)
        spread = max(float(np.abs(fit_regularized(profile, train, family, strength) - matrix).max()) for train, _ in folds(sets))
        print(f"{name}: rows sum {np.round(matrix.sum(axis=1), 9)}; largest change across the folds {spread:.4f}")
        print(np.array2string(matrix, precision=4, suppress_small=True))
        print(f"  {family} {strength}; row lengths {np.round(np.linalg.norm(matrix, axis=1), 3)}")
        if args.write:
            write_matrix(path, matrix)


BASIS = ("fitted (bake/tools/fit_exposure_matrix.py) by least squares on log10 layer exposure, rows summing to one "
         "so grays stay neutral, over measured reflectances under D55: Morimoto, Zhang, Fukuda and Uchikawa's 307 "
         "natural objects (Zenodo 5217752, CC BY 4.0) and NIST's 100 forearms (public domain), the two sets "
         "weighted equally (docs/research/film-sim/bakelook.md section 2); regularized as REGULARIZATION names, chosen by "
         "package G's criterion (docs/research/film-sim/matrix.md section 3)")


def write_matrix(path: Path, matrix: np.ndarray) -> None:
    """Put the matrix into the profile's "exposureMatrix" section, after "couplers", keeping the file's layout."""
    text = path.read_text(encoding="utf-8")
    rows = ", ".join("[" + ", ".join(f"{v:.6f}" for v in row) + "]" for row in matrix)
    block = (f'  "exposureMatrix": {{\n    "matrix": [{rows}],\n    "basis": {json.dumps(BASIS)}\n  }},\n')
    start = text.find('  "exposureMatrix": {')
    if start >= 0:
        end = text.index("  },\n", start) + len("  },\n")
        text = text[:start] + block + text[end:]
    else:
        anchor = text.index('  "halation": {')
        text = text[:anchor] + block + text[anchor:]
    json.loads(text)
    path.write_text(text, encoding="utf-8")

if __name__ == "__main__":
    main()
