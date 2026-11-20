"""A stand-in for a release argent-spike with all five Presence stages: today's spike (the main checkout's release
build) with each fit's Python prototype behind its flag. The scorecard scores it to prove itself end to end before
any Swift stage exists, as `fit_dehaze.py spike-check` and V3's opt-in test do for one slider each.

    .venv/bin/python -I scripts/presence/stand_in.py ARGS     runs as `argent-spike ARGS` would

- --dehaze V: `fit_dehaze.py emulate-spike`, F2's stage on the decode through --scene-in.
- --clarity V and --texture V: `fit_clarity_round2.py emulate-spike`, F1's stage on the decode through --scene-in.
- --saturation V and --vibrance V: the real spike's print, then V3's stage on it at the stock's strength, as V3's test
  stand-in applies it.

A value of 0, or no Presence flag, runs the real spike untouched.
"""
import os
import subprocess
import sys
from pathlib import Path

import numpy as np

KIT = Path(__file__).resolve().parents[1] / "lightroom-probe"
sys.path.insert(0, str(KIT))
import fit_colour as C  # noqa: E402

SCENE_STAGES = {"--dehaze": KIT / "fit_dehaze.py", "--clarity": KIT / "fit_clarity_round2.py",
                "--texture": KIT / "fit_clarity_round2.py"}
PRINT_STAGES = ("saturation", "vibrance")


def launcher(folder):
    """An executable `argent-spike` in `folder` that runs this stand-in."""
    path = Path(folder) / "argent-spike"
    path.write_text(f"#!/bin/sh\nexec {sys.executable} -I {Path(__file__).resolve()} \"$@\"\n")
    path.chmod(0o755)
    return path


def print_stage(args):
    """The real spike's print, then V3's stage on the print array, as V3's stand-in build applies it."""
    slider = next(s for s in PRINT_STAGES if f"--{s}" in args)
    i = args.index(f"--{slider}")
    value = int(float(args[i + 1]))
    del args[i:i + 2]
    run = subprocess.run([str(C.SPIKE), *args])
    if run.returncode or not value:
        return run.returncode
    path = args[args.index("--print-out") + 1]
    stock = Path(args[args.index("--stock") + 1]).name
    v = C.stage_variant(slider, value, stock, C.fitted_strengths())
    P = C.vibrance_constants()["hsv"]["constants"]
    np.save(path, C.chunked(lambda c: next(iter(C.METHODS[v[2]](c, value / 100, [v[3]], P))), np.load(path)))
    return 0


def main(args):
    for flag, script in SCENE_STAGES.items():
        if flag in args:
            os.execv(sys.executable, [sys.executable, "-I", str(script), "emulate-spike", *args])
    if any(f"--{s}" in args for s in PRINT_STAGES):
        return print_stage(list(args))
    os.execv(str(C.SPIKE), [str(C.SPIKE), *args])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
