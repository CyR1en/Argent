"""Auto's tone step's base under Dehaze, recorded: `fit_dehaze.py`'s own `Field.transmission` and `dehaze` run on a grey at each
base's level, written as a Swift test fixture, so `PresenceScene.dehazedBase` is held to the fit's Dehaze without the probe kit.

The cases are the scene fixture's (`PresenceSceneFitFixture.swift`, which `scene_fixture.py` writes): each recorded pixel and each floor
case, its base the guide of its light as `probe.ToneBase` makes it, log2(sqrt(Y^2 + 1e-12)) held to 40 stops, under the coefficients
recorded with it. Then stated bases below, at and above the floor of the guide the transmission's field is read under, log2(1e-6),
which half floats can round a base past, under the scene fixture's floor coefficients. Then, under each of those coefficients, the
base whose dehazed luminance crosses 0 at Dehaze +100, where its two terms cancel. The airlight is the scene fixture's, as the Swift
test reads it. Run from the repository root, after `scene_fixture.py`:

    .venv/bin/python -I scripts/presence/scene/dehazed_base_fixture.py

For each case and value: the grey (y, y, y), y = 2^base, through `Field.transmission` (t at log2(max(Y, 1e-6)) of the grey) and
`dehaze` (the gain, the fade at the grey's own ratio, A + (grey - A) G), and log2 of the result's luminance held to the floor of
`Field`'s own guide, 1e-6, and to 40 stops: light Dehaze takes below black is the darkest base.
"""
import json
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scene_fixture as SF  # noqa: E402

FD = SF.FD
SOURCE = SF.ROOT / "Tests" / "ArgentCoreTests" / "PresenceSceneFitFixture.swift"
OUT = SF.ROOT / "Tests" / "ArgentCoreTests" / "PresenceDehazedBaseFixture.swift"
GUIDE_FLOOR = 1e-6
FLOOR = float(np.log2(GUIDE_FLOOR))
STATED_BASES = [-30.0, -21.0, FLOOR - 0.02, FLOOR, FLOOR + 0.02, -19.0, -16.0]


def recorded(text, name, per_row):
    body = re.search(rf"static let {name}: \[Float\] = \[(.*?)\n    \]", text, re.S).group(1)
    return np.array([np.float32(v) for v in re.findall(r"[-+0-9.e]+", body)], dtype=np.float32).reshape(-1, per_row)


def guide(Y):
    return np.clip(np.log2(np.sqrt(Y ** 2 + 1e-12)), -40, 40)


def floored(Y):
    return np.clip(np.log2(np.maximum(Y, GUIDE_FLOOR)), -40, 40)


def through_dehaze(base, ab, airlight, c, values):
    """`dehaze` of the grey at each base under its own coefficients, as `scene_fixture.floor_cases` runs the prototype per case: a
    frame two pixels wide whose rows are the cases, under grids that hold each case's (a, b) on its row. The rows are padded to a
    power of two, where `sample_at`'s (p + 0.5) / n * n - 0.5 is p exactly, so no row takes a share of its neighbour's."""
    count = len(base)
    rows = 1 << max(1, (count - 1).bit_length())
    base, ab = np.concatenate([base, np.repeat(base[-1:], rows - count)]), np.concatenate([ab, np.repeat(ab[-1:], rows - count, axis=0)])
    fld = object.__new__(FD.Field)
    fld.A = airlight
    fld.shape = (rows, 2)
    fld.a, fld.b = (np.repeat(ab[:, k:k + 1], 2, axis=1) for k in (0, 1))
    assert all(np.allclose(FD.sample_at(grid, fld.shape), grid, rtol=1e-15, atol=0) for grid in (fld.a, fld.b))
    grey = np.repeat(np.repeat(np.exp2(base)[:, None, None], 3, axis=2), 2, axis=1)
    return np.stack([FD.dehaze(grey, v, fld, c)[:count, 0] @ FD.Y2020 for v in values], axis=1)


def crossings(ab, airlight, c):
    """Under each (a, b), the base nearest where the grey's dehazed luminance at +100 crosses 0, from below the floor to the
    airlight's own level, by bisection; none where it does not cross."""
    found = []
    for row in ab:
        def luminance(b):
            return float(through_dehaze(np.array([b]), row[None, :], airlight, c, [100])[0, 0])
        grid = np.linspace(-22, np.log2(airlight @ FD.Y2020), 4000)
        signs = np.sign(through_dehaze(grid, np.repeat(row[None, :], len(grid), axis=0), airlight, c, [100])[:, 0])
        change = np.flatnonzero(signs[:-1] * signs[1:] < 0)
        if len(change) == 0:
            continue
        low, high = grid[change[0]], grid[change[0] + 1]
        for _ in range(80):
            middle = (low + high) / 2
            low, high = (middle, high) if np.sign(luminance(middle)) == np.sign(luminance(low)) else (low, middle)
        found.append((np.float32((low + high) / 2), *row))
    return found


def main():
    text = SOURCE.read_text()
    pixels, floor = recorded(text, "pixels", 11), recorded(text, "floorCases", 5)
    airlight = np.array([np.float32(v) for v in re.search(r"static let airlight = SIMD3<Float>\((.*?)\)", text).group(1).split(",")],
                        dtype=np.float32).astype(np.float64)
    assert len(pixels) == 160 and len(floor) == 48
    constants = json.loads((SF.INPUTS / "dehaze.json").read_text())["candidates"]["dark-channel"]["constants"]
    c = FD.Constants(**constants)
    stated_ab = np.array(SF.FLOOR_COEFFICIENTS, dtype=np.float32)

    cases = [(guide(p[:3].astype(np.float64) @ FD.Y2020), p[3], p[4]) for p in pixels]
    cases += [(guide(p[:3].astype(np.float64) @ FD.Y2020), p[3], p[4]) for p in floor]
    cases += [(b, *ab) for b in STATED_BASES for ab in stated_ab]
    zero = crossings(stated_ab.astype(np.float64), airlight, c)
    cases += zero
    cases = np.array(cases, dtype=np.float64).astype(np.float32)

    Y = through_dehaze(cases[:, 0].astype(np.float64), cases[:, 1:].astype(np.float64), airlight, c, SF.DEHAZE_VALUES)
    dehazed = floored(Y)

    lines = [
        "// Generated by scripts/presence/scene/dehazed_base_fixture.py from fit_dehaze.py, with the inputs in scripts/presence/2026-11-11-1,",
        "// on the cases of PresenceSceneFitFixture.swift. Run it again rather than edit this.",
        "",
        "/// Auto's tone step's base under Dehaze, by the fit's own Dehaze (`PresenceSceneFitTests`): each case's base and the coefficients of",
        "/// Dehaze's field at it, and log2 of the luminance `fit_dehaze.py`'s `dehaze` makes of a grey at that base at each value of",
        "/// `PresenceSceneFitFixture.dehazeValues`, under its airlight, held to the floor of its guide, 1e-6.",
        "enum PresenceDehazedBaseFixture {",
        f"    static let recordedCount = {len(pixels)}, floorCount = {len(floor)}, statedCount = {len(STATED_BASES) * len(stated_ab)}, "
        f"crossingCount = {len(zero)}",
        "",
    ]
    lines += SF.rows("cases", "Per case: its base in log2 luminance, then (a, b), in the order of the counts above.", cases, 9)
    lines += ["", *SF.rows("dehazedBases", "Per case, per Dehaze value: log2 of the fit's dehazed luminance, held to the floor.", dehazed, 8)]
    lines += ["}", ""]
    OUT.write_text("\n".join(lines))

    print(f"{len(cases)} cases: {len(pixels)} recorded, {len(floor)} floor, {len(STATED_BASES) * len(stated_ab)} stated, {len(zero)} crossings")
    print(f"bases {cases[:, 0].min():.3f} to {cases[:, 0].max():.3f}; below the guide's floor {int((cases[:, 0] < FLOOR).sum())}")
    print(f"dehazed luminance below 0 {int((Y < 0).sum())} of {Y.size}; |Y| under 1e-5 {int((np.abs(Y) < 1e-5).sum())}; "
          f"held at the floor {int((Y <= GUIDE_FLOOR).sum())}")
    print("crossings at +100: " + ", ".join(f"base {b:.6f} under ({a:g}, {bb:g}): Y {float(Y[i, SF.DEHAZE_VALUES.index(100)]):.3e}"
                                           for i, (b, a, bb) in enumerate(cases[-len(zero):], start=len(cases) - len(zero)))
          if zero else "crossings: none")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
