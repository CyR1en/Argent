"""Writes Tests/ArgentCoreTests/PresencePrintFixture.swift: fit_colour.py's sat_lightroom and vib_hsv on synthetic print colours.
Run from the repository root:

    .venv/bin/python -I scripts/presence/print/print_fixture.py

The colours sweep the skin window by Oklab hue, HSV saturation from 0 to 1 through the knee, and lightness, with black, greys, light
above white and negative channels. They are made in linear ProPhoto, taken to linear Rec. 2020 as the print stage reads light, and
rounded to float32, which both sides read. Vibrance's constants come from the repository's scripts/presence/<version>/colour.json, so a
refresh of the inputs is followed by running this again. Every output is float64 rounded to float32, stored as little-endian bytes.
"""
import base64
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
version = "2026-11-11-1"
sys.path.insert(0, str(ROOT / "scripts" / "lightroom-probe"))
import fit_colour as fc  # noqa: E402

P = json.loads((ROOT / "scripts" / "presence" / version / "colour.json").read_text())["vibrance"]["constants"]["hsv"]
LUMA = fc.LR_LUMA["rec2020"]
STRENGTH = {"kodak-portra-400": (1.45, 1.72)}


def oklch(L, C, h):
    a = np.radians(h)
    return fc.oklab_to_rgb(np.stack([np.full_like(a, L), C * np.cos(a), C * np.sin(a)], -1), "prophoto")


def hsv(V, S, weights):
    return V * (1 - S[:, None] * (1 - np.asarray(weights)[None, :]))


window = fc.vibrance_constants()["hsv"]["constants"]["pos"]
hues = np.concatenate([window["hc"] + np.arange(-100, 101, 10.0), [window["hc"] - window["hw"], window["hc"] + window["hw"]]])
S = np.linspace(0, 1, 21)
prophoto = np.concatenate([
    oklch(0.55, 0.04, hues), oklch(0.55, 0.12, hues),
    hsv(0.35, S, (1, 0.35, 0)), hsv(0.35, S, (0, 0.4, 1)),
    hsv(np.array([0.002, 0.01, 0.03, 0.08, 0.18, 0.35, 0.6, 0.9, 1.2, 2.0])[:, None], np.full(10, 0.4), (0.2, 1, 0.5)),
])
rec2020 = np.concatenate([fc.from_prophoto(prophoto, "rec2020"), [
    [0, 0, 0], [0.18, 0.18, 0.18], [1, 1, 1], [1, 0, 0], [0, 1, 0], [0, 0, 1],
    [-0.02, 0.3, 0.5], [0.2, -0.05, -0.05], [-0.01, -0.02, -0.005], [1.5, 0.2, 0.05]]])
colours = rec2020.astype(np.float32)
c = colours.astype(np.float64)


def staged(saturation, vibrance, stock):
    out = c if saturation == 0 else fc.sat_lightroom(c, saturation / 100, LUMA)
    if vibrance:
        m = STRENGTH.get(stock, (1.0, 1.0))[0 if vibrance > 0 else 1]
        out = fc.vib_hsv(out, vibrance / 100, P, "rec2020", m=m)
    return out


cases = [(0, v, "light-toy") for v in (-100, -50, -25, 25, 50, 100)]
cases += [(0, v, "kodak-portra-400") for v in (-100, -50, 50, 100)]
cases += [(v, 0, "light-toy") for v in (-100, -50, 50, 100)]
cases += [(50, 50, "light-toy"), (-50, -100, "light-toy")]


def blob(a):
    return base64.b64encode(np.ascontiguousarray(a, "<f4").tobytes()).decode()


lines = [
    "// Written by scripts/presence/print/print_fixture.py from scripts/lightroom-probe/fit_colour.py and",
    f"// scripts/presence/{version}/colour.json. Do not edit: run it again.",
    "extension PresencePrintTests {",
    f"    /// {len(colours)} print colours, linear Rec. 2020, float32: the skin window by Oklab hue, HSV saturation 0 to 1 through the",
    "    /// knee, lightness, and black, greys, light above white and negative channels.",
    f'    static let fixtureColours = "{blob(colours)}"',
    "",
    "    /// `sat_lightroom`, then `vib_hsv` at the stock's strength (Portra 400 1.45 and 1.72 here, every other stock 1), on each colour.",
    "    static let fixtureCases: [(saturation: Float, vibrance: Float, stock: String, output: String)] = [",
]
for saturation, vibrance, stock in cases:
    with np.errstate(invalid="ignore"):
        out = staged(saturation, vibrance, stock)
    lines.append(f'        ({saturation}, {vibrance}, "{stock}", "{blob(out)}"),')
lines += ["    ]", "}", ""]
path = ROOT / "Tests" / "ArgentCoreTests" / "PresencePrintFixture.swift"
path.write_text("\n".join(lines))
print(f"{len(colours)} colours, {len(cases)} cases, written to {path}")
