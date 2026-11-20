"""The scene stages' recorded pixels: the fits' own prototypes of Dehaze, Clarity and Texture run on a real decode, written as a Swift
test fixture, so `PresenceScene.applying` is held to `fit_dehaze.py`'s `dehaze` and `fit_texture_clarity.py`'s stage without the probe
kit.

It decodes the CC0 probe raw (raw.pixls.us ILCE-7M4, permitted data) at a quarter of full size with the checkout's release spike, as
`--scene-out` writes the decode the film's render receives, and writes Tests/ArgentCoreTests/PresenceSceneFitFixture.swift. Run from
the repository root, in a checkout with samples/, build/stocks and a release spike (`swift build -c release --product argent-spike`):

    .venv/bin/python -I scripts/presence/scene/scene_fixture.py

What each prototype is given, from the fit scripts' own functions:

- Dehaze: `fit_dehaze.Field` of the whole decode with the recommended constants (`dehaze.json`, dark-channel), its (a, b) at each pixel
  by `sample_at`, `t` by `Field.transmission`, and `dehaze` at each value. Two values also with Exposure before Dehaze, the field made
  from the exposed decode, which is the prototype's reading of "Exposure multiplies the dehazed light, Dehaze with 2^E A".
- Dehaze's floor cases, which no photograph reaches: light whose luminance is below 0, at 0 and within four stops of the guide's floor
  (`Field`'s log2(max(Y, 1e-6))), each under stated coefficients and the decode's airlight, `Field.transmission` and `dehaze` at each
  value. The review's case comes first: (a, b) = (0.05, 0.9) at the light (0.1, -0.1, 0).
- Clarity and Texture: `guided_coefficients` and `texture_band` on the decode's luminance as `FilmFrame` holds it (float32, g floored
  at 2^-20), `strength` and `weight_at` with the constants' laws and weights, so delta = k(v) m(L*(base)) D. The print's transfer from
  scene stops to L* is a stated line, L* = 50 + x / 0.15 clipped to 0 and 100: the weights through a stock's transfer are package A's to
  prove, and with this line every kink of m(L*(x)) falls on a sample of the Swift test's tables, so they hold m exactly.
"""
import json
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
KIT = ROOT / "scripts" / "lightroom-probe"
sys.path.insert(0, str(KIT))
import fit_dehaze as FD  # noqa: E402
import fit_texture_clarity as FT  # noqa: E402
import probe  # noqa: E402

RAW = ROOT / "samples" / "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"
SPIKE = ROOT / ".build" / "release" / "argent-spike"
STOCK = ROOT / "build" / "stocks" / "kodak-portra-400"
INPUTS = ROOT / "scripts" / "presence" / "2026-11-11-1"
OUT = ROOT / "Tests" / "ArgentCoreTests" / "PresenceSceneFitFixture.swift"
SCALE = 0.25
COUNT = 160
DEHAZE_VALUES = [-100, -63, -25, -10, 10, 40, 75, 100]
EXPOSED = [(1.3, 50), (-0.7, -100)]
FLOOR_LIGHT = [(0.1, -0.1, 0.0), (-0.002, -0.001, -0.003), (0.05, -0.03, 0.02), (-0.3, 0.02, 0.1), (2e-6, -3e-6, 1e-6),
               (0.0, 0.0, 0.0), *((y, y, y) for y in (5e-7, 1e-6, 2e-6, 4e-6, 1.6e-5)), (6e-6, 1e-6, 2e-5)]
FLOOR_COEFFICIENTS = [(0.05, 0.9), (-0.02, 0.6), (-0.0035, 0.97), (0.02, 0.5)]
DETAIL_VALUES = [-100, -75, -40, -10, 25, 60, 100]
TRANSFER_SLOPE = 0.15
TABLE_START, TABLE_STEP = -12.8, 0.05


def lightness(x):
    return np.clip(50 + x / TRANSFER_SLOPE, 0, 100)


def decode():
    with tempfile.TemporaryDirectory() as out:
        probe.spike(RAW, out, STOCK, "--scale", SCALE, "--no-lens", "--tiff", "--scene-out", Path(out) / "scene.npy", binary=SPIKE)
        return np.load(Path(out) / "scene.npy")


def chosen(Y, t, A_Y, rng):
    """Pixels across the frame's levels, its transmission and the fade band: ranks evenly spaced in luminance, then in t, then the
    pixels between 1 and 2 times the airlight's luminance and past it."""
    flat = np.flatnonzero(Y.ravel() > 1e-4)
    by_y = flat[np.argsort(Y.ravel()[flat])]
    by_t = flat[np.argsort(t.ravel()[flat])]
    picks = list(by_y[np.linspace(0, len(by_y) - 1, COUNT // 2).astype(int)])
    picks += list(by_t[np.linspace(0, len(by_t) - 1, COUNT // 4).astype(int)])
    for low, high in ((1, 2), (2, np.inf)):
        band = flat[(Y.ravel()[flat] >= low * A_Y) & (Y.ravel()[flat] < high * A_Y)]
        picks += list(rng.choice(band, size=min(len(band), COUNT // 8), replace=False))
    picks = list(dict.fromkeys(int(p) for p in picks))
    return np.array(picks[:COUNT])


def floor_cases(airlight, c):
    """Each of `FLOOR_LIGHT` under each of `FLOOR_COEFFICIENTS`, in float32 as the fixture holds them, through the prototype's own
    per-pixel step: a frame two pixels wide whose rows are the cases, under grids of its size that hold each case's coefficients on
    its row, so `sample_at` reads them back as they are. Returns the light, the coefficients, t and the result at each value."""
    light = np.array([rgb for rgb in FLOOR_LIGHT for _ in FLOOR_COEFFICIENTS], dtype=np.float32).astype(np.float64)
    ab = np.array([ab for _ in FLOOR_LIGHT for ab in FLOOR_COEFFICIENTS], dtype=np.float32).astype(np.float64)
    fld = object.__new__(FD.Field)
    fld.A = airlight.astype(np.float32).astype(np.float64)
    fld.shape = (len(light), 2)
    fld.a, fld.b = (np.repeat(ab[:, k:k + 1], 2, axis=1) for k in (0, 1))
    assert all(np.allclose(FD.sample_at(grid, fld.shape), grid, rtol=1e-15, atol=0) for grid in (fld.a, fld.b))
    frame = np.repeat(light[:, None, :], 2, axis=1)
    dehazed = np.stack([FD.dehaze(frame, v, fld, c)[:, 0] for v in DEHAZE_VALUES], axis=1)
    return light, ab, fld.transmission(frame, c)[:, 0], dehazed


def number(v):
    v = np.float32(v)
    if v == 0:
        return "0"
    if 1e-3 <= abs(v) < 1e4:
        return np.format_float_positional(v, unique=True, trim="-")
    return np.format_float_scientific(v, unique=True, trim="-")


def rows(name, doc, values, per_row):
    lines = [f"    /// {doc}", f"    static let {name}: [Float] = ["]
    flat = [number(v) for v in np.asarray(values, dtype=np.float64).ravel()]
    for i in range(0, len(flat), per_row):
        lines.append("        " + ", ".join(flat[i:i + per_row]) + ",")
    lines.append("    ]")
    return lines


def main():
    rng = np.random.default_rng(20261111)
    scene32 = decode()
    h, w = scene32.shape[:2]
    scene = scene32.astype(np.float64)

    dehaze_constants = json.loads((INPUTS / "dehaze.json").read_text())["candidates"]["dark-channel"]["constants"]
    c = FD.Constants(**dehaze_constants)
    field = FD.Field(scene, c)
    t = field.transmission(scene, c)
    a_d, b_d = FD.sample_at(field.a, (h, w)), FD.sample_at(field.b, (h, w))
    Y = scene @ FD.Y2020
    picks = chosen(Y, t, float(field.A @ FD.Y2020), rng)
    ys, xs = np.unravel_index(picks, (h, w))
    rgb = scene[ys, xs]
    dehazed = np.stack([FD.dehaze(rgb, v, field, c, t=t[ys, xs]) for v in DEHAZE_VALUES], axis=1)
    exposed = []
    for exposure, v in EXPOSED:
        lit = scene * 2.0 ** exposure
        lit_field = FD.Field(lit, c)
        lit_t = lit_field.transmission(lit, c)
        exposed.append(FD.dehaze(lit[ys, xs], v, lit_field, c, t=lit_t[ys, xs]))
        del lit
    exposed = np.stack(exposed, axis=1)
    floor_light, floor_ab, floor_t, floor_dehazed = floor_cases(field.A, c)

    # The detail stage as FilmFrame holds the decode: float32 luminance, g floored at 2^-20.
    Y32 = scene32 @ FT.REC2020_Y
    g = np.log2(np.maximum(Y32, 2.0 ** -20)).astype(np.float32)
    rec = json.loads((INPUTS / "clarity-round2.json").read_text())["recommendation"]["clarity-guided"]
    texture = json.loads((INPUTS / "texture-clarity.json").read_text())["candidates"]["texture-guided-band"]
    coefficients, stops = {}, {}
    for name, side in (("clarityPositive", rec["positive"]), ("clarityNegative", rec["negative"])):
        p = side["params"]
        a, b = FT.guided_coefficients(Y32, p["field"], p["radius"], p["epsilon"], p.get("share", 0.5))
        coefficients[name] = (probe.ToneBase.sample(a, Y32.shape), probe.ToneBase.sample(b, Y32.shape))
        D, base = FT.make_detail(side, Y32, g)
        assert np.allclose(base, coefficients[name][0].astype(np.float32) * g + coefficients[name][1].astype(np.float32), atol=1e-5)
    p = texture["positive"]["params"]
    long_side = max(Y32.shape)
    F = min(long_side, max(16, int(round(long_side / SCALE * p["field_scale"]))))
    a, b = FT.guided_coefficients(Y32, F, p["radius_px"] * SCALE / long_side, p["epsilon"], p.get("share", 0.5))
    coefficients["texture"] = (probe.ToneBase.sample(a, Y32.shape), probe.ToneBase.sample(b, Y32.shape))
    band = FT.texture_band(Y32, g, p, SCALE)
    assert np.allclose(band[1], coefficients["texture"][0].astype(np.float32) * g + coefficients["texture"][1].astype(np.float32), atol=1e-5)
    details = {"clarity": {True: FT.make_detail(rec["positive"], Y32, g), False: FT.make_detail(rec["negative"], Y32, g)},
               "texture": {True: band, False: band}}
    sides = {"clarity": {True: rec["positive"], False: rec["negative"]}, "texture": {True: texture["positive"], False: texture["negative"]}}
    largest = {}
    for control in ("clarity", "texture"):
        rows_ = []
        for v in DETAIL_VALUES:
            s = sides[control][v > 0]
            D, base = details[control][v > 0]
            Lb = lightness(np.log2(np.maximum(np.exp2(base[ys, xs]), 2.0 ** -20) / 0.18))
            rows_.append((FT.strength(s, v) * FT.weight_at(s, Lb) * D[ys, xs]).astype(np.float32))
            whole = FT.strength(s, v) * FT.weight_at(s, lightness(np.log2(np.maximum(np.exp2(base), 2.0 ** -20) / 0.18))) * D
            largest[(control, v)] = float(np.abs(whole).max())
            del whole
        stops[control] = np.stack(rows_, axis=1)

    pixels = np.concatenate([rgb, np.stack([a_d[ys, xs], b_d[ys, xs]], axis=1)]
                            + [np.stack([coefficients[k][0][ys, xs], coefficients[k][1][ys, xs]], axis=1)
                               for k in ("clarityPositive", "clarityNegative", "texture")], axis=1)
    A = field.A
    lines = [
        "// Generated by scripts/presence/scene/scene_fixture.py from fit_dehaze.py and fit_texture_clarity.py, with the inputs in",
        "// scripts/presence/2026-11-11-1, on the CC0 probe raw (samples/ILCE-7M4_DSC06674) decoded at a quarter of full size. Run it again",
        "// rather than edit this.",
        "",
        "/// The fits' prototypes on recorded pixels (`PresenceSceneFitTests`): each pixel's light and the coefficients the fields hold at it,",
        "/// and what `fit_dehaze.py`'s `dehaze` and `fit_texture_clarity.py`'s stage make of it at each value.",
        "enum PresenceSceneFitFixture {",
        f"    static let frame = (width: {w}, height: {h})",
        f"    static let airlight = SIMD3<Float>({number(A[0])}, {number(A[1])}, {number(A[2])})",
        f"    static let dehazeValues: [Float] = [{', '.join(str(v) for v in DEHAZE_VALUES)}]",
        f"    static let exposed: [(exposure: Float, dehaze: Float)] = [{', '.join(f'({e}, {v})' for e, v in EXPOSED)}]",
        f"    static let detailValues: [Float] = [{', '.join(str(v) for v in DETAIL_VALUES)}]",
        "    /// The print's lightness against scene stops from the reference that the prototype's stage was given: L* = 50 + x / slope, held",
        "    /// to 0 and 100. Its kinks fall on the samples of tables that start at `tableStart` and step by `tableStep`.",
        f"    static let transferSlope: Float = {TRANSFER_SLOPE}",
        f"    static let tableStart: Float = {TABLE_START}, tableStep: Float = {TABLE_STEP}",
        f"    static let count = {len(picks)}",
        f"    static let floorCount = {len(floor_light)}",
        "",
    ]
    lines += rows("pixels", "Per pixel: r, g, b, then (a, b) of Dehaze, Clarity's positive and negative fields and Texture's band.",
                  pixels, 11)
    lines += ["", *rows("dehazed", "Per pixel, per Dehaze value: the prototype's r, g, b.", dehazed.reshape(len(picks), -1), 12)]
    lines += ["", *rows("exposedDehazed", "Per pixel, per `exposed` case: the prototype's r, g, b, Dehaze on the exposed decode.",
                        exposed.reshape(len(picks), -1), 6)]
    lines += ["", *rows("floorCases", "Dehaze's floor cases, the review's first: luminance below 0, at 0 and near the guide's floor. "
                        "Per case: r, g, b, then (a, b).", np.concatenate([floor_light, floor_ab], axis=1), 5)]
    lines += ["", *rows("floorDehazed", "Per floor case, per Dehaze value: the prototype's r, g, b.",
                        floor_dehazed.reshape(len(floor_light), -1), 12)]
    lines += ["", *rows("clarityStops", "Per pixel, per detail value: Clarity's delta in stops.", stops["clarity"], 7)]
    lines += ["", *rows("textureStops", "Per pixel, per detail value: Texture's delta in stops.", stops["texture"], 7)]
    lines += ["}", ""]
    OUT.write_text("\n".join(lines))

    print(f"decode {w} x {h}, {len(picks)} pixels, airlight {A}, luminance {float(A @ FD.Y2020):.4f}")
    print(f"t at the pixels {t[ys, xs].min():.3f} to {t[ys, xs].max():.3f}; luminance {Y[ys, xs].min():.2e} to {Y[ys, xs].max():.2e}; "
          f"between 1 and 2 airlights {int(((Y[ys, xs] >= A @ FD.Y2020) & (Y[ys, xs] < 2 * A @ FD.Y2020)).sum())}, past {int((Y[ys, xs] >= 2 * A @ FD.Y2020).sum())}")
    floor_y = floor_light @ FD.Y2020
    under_light = np.clip(floor_ab[:, 0] * np.log2(np.sqrt(floor_y ** 2 + 1e-12)) + floor_ab[:, 1], c.t_min, 1)
    print(f"floor cases {len(floor_light)}: luminance {floor_y.min():.2e} to {floor_y.max():.2e}, {int((floor_y < 0).sum())} below 0; "
          f"the review's t {floor_t[0]:.4f} (under Light's guide {under_light[0]:.4f}); largest gap in t from Light's guide "
          f"{np.abs(floor_t - under_light).max():.4f}, cases apart by more than 1e-4 {int((np.abs(floor_t - under_light) > 1e-4).sum())}")
    for control in ("clarity", "texture"):
        s = stops[control]
        print(f"{control}: recorded stops {s.min():+.3f} to {s.max():+.3f}; past the 4-stop limit {int((np.abs(s) >= 4).sum())}")
        print("  largest |delta| over the whole quarter-size frame: " + ", ".join(f"{v:+d} {largest[(control, v)]:.3f}" for v in DETAIL_VALUES))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
