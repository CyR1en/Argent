"""Dehaze's field on small synthetic hazy scenes, made by fit_dehaze.py's own Field and helpers, recorded for
PresenceAnalysisBuilderTests (Tests/ArgentCoreTests): each scene as half floats, the constants it was made with, and what Field
makes of it, the airlight, the eroded normalised dark channel and the boxed coefficients (a, b). Pixels are written as half floats'
bit patterns, row by row and red, green, blue; what Field makes to 9 significant digits.

Three cases: a field smaller than the scene by an uneven ratio with radii of several field pixels, the same with the airlight's
brightness share above 0, and the version's own constants on a scene under 1024 pixels, where the field is the scene. Run from the
repository root:

    .venv/bin/python -I scripts/presence/analysis/haze_fixture.py
"""

import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "lightroom-probe"))
import fit_dehaze  # noqa: E402
import probe  # noqa: E402

OUT = Path(__file__).with_name("haze-fixture.json")


def scene(width, height, seed):
    """A hazy scene in linear Rec. 2020: a bright sky above, dark textured ground veiled more toward the horizon, a red patch, and a
    light brighter than the haze, with a little noise; rounded to half floats, as a decode's texture holds it."""
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:height, 0:width]
    v, u = y / height, x / width
    airlight = np.array([1.15, 1.2, 1.32])
    ground = np.stack([0.03 + 0.04 * u, 0.05 + 0.03 * np.sin(9 * u), 0.02 + 0.02 * v], axis=-1)
    ground *= 1 + 0.6 * ((x // 3 + y // 2) % 2)[..., None]
    ground[(u > 0.55) & (u < 0.7) & (v > 0.6)] = [0.35, 0.04, 0.03]
    t = np.exp(-2.2 * np.clip(1 - v, 0, 1))[..., None]
    img = ground * t + airlight * (1 - t)
    img[v < 0.25] = airlight * (0.97 + 0.06 * u[v < 0.25, None])
    img[(np.abs(u - 0.8) < 0.03) & (np.abs(v - 0.15) < 0.04)] = [3.0, 2.8, 2.5]
    img *= 1 + 0.02 * rng.standard_normal(img.shape)
    return np.maximum(img, 0).astype(np.float16)


CASES = [
    ("a field smaller than the scene", 60, 40, 1,
     dict(long_side=32, airlight_radius=0.1, airlight_quantile=0.99, airlight_bright=0.0, dark_radius=0.05, guide_radius=0.15,
          epsilon=0.5)),
    ("the airlight's brightest half", 60, 40, 2,
     dict(long_side=32, airlight_radius=0.1, airlight_quantile=0.95, airlight_bright=0.5, dark_radius=0.05, guide_radius=0.15,
          epsilon=0.5)),
    ("the version's constants, the scene its own field", 64, 48, 3,
     dict(long_side=1024, airlight_radius=0.012, airlight_quantile=0.999, airlight_bright=0.0, dark_radius=0.006,
          guide_radius=0.06, epsilon=0.5)),
]


def digits(values):
    return [float(f"{v:.9g}") for v in np.asarray(values, dtype=np.float64).reshape(-1)]


def case(name, width, height, seed, settings):
    c = fit_dehaze.Constants(method="dark-channel", omega=0.95, opening=False, **settings)
    halves = scene(width, height, seed)
    img = halves.astype(np.float64)
    fld = fit_dehaze.Field(img, c)
    F = fit_dehaze.area_down(img, c.long_side)
    dark = fit_dehaze.erode((F / fld.A).min(-1), max(0, probe.rounded(c.dark_radius * max(F.shape[:2]))))
    return {
        "name": name,
        "width": width,
        "height": height,
        "pixels": halves.view(np.uint16).reshape(-1).tolist(),
        "constants": {"longSide": c.long_side, "omega": c.omega, "airlightRadius": c.airlight_radius,
                      "airlightQuantile": c.airlight_quantile, "airlightBrightShare": c.airlight_bright,
                      "darkRadius": c.dark_radius, "guideRadius": c.guide_radius, "epsilon": c.epsilon},
        "fieldWidth": F.shape[1],
        "fieldHeight": F.shape[0],
        "airlight": fld.A.tolist(),
        "dark": digits(dark),
        "a": digits(fld.a),
        "b": digits(fld.b),
    }


def main():
    cases = [case(*spec) for spec in CASES]
    OUT.write_text(json.dumps({"script": "scripts/presence/analysis/haze_fixture.py, fit_dehaze.py's Field", "cases": cases}) + "\n")
    for c in cases:
        print(f"{c['name']}: field {c['fieldWidth']}x{c['fieldHeight']}, airlight {np.round(c['airlight'], 4).tolist()}")


if __name__ == "__main__":
    main()
