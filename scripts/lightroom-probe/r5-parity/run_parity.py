"""Parity of the analysis' Python port of R5's arithmetic with R5's own Swift reference.

R5's `SceneCPU.gains` (harness/cpuref.swift, compiled unmodified with its snapshot of Sources/ArgentCore and `main.swift`
here) and `mask_models.RampTables.r5_level` are run on the same random tables, levels, bases, exposures and coverages; the
tone gains in stops must agree to float32 rounding. The tables here are arrays of gains on a grid, which is what
`ManualToneTables` holds; in the analysis the same tables come from Lightroom's own renders.

    swiftc -O -swift-version 5 -module-name Harness -o parity $(find $R5/snapshot/ArgentCore -name '*.swift') \
        $R5/harness/cpuref.swift main.swift                    # about 25 s, DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    python -I run_parity.py ./parity [cases]
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import mask_models as mm  # noqa: E402


class ArrayTables(mm.RampTables):
    """RampTables whose layers carry R5's two tables as arrays ('_L' local, '_G' global) on a grid, read by linear interpolation."""

    def __init__(self, grid):
        self.grid = grid

    def layer_local(self, values, level):
        table = values.get("_L")
        return np.zeros(np.shape(level)) if table is None else np.interp(level, self.grid, table)

    def layer_global(self, values, level):
        table = values.get("_G")
        return np.zeros(np.shape(level)) if table is None else np.interp(level, self.grid, table)


def random_table(rng, grid):
    amp = rng.uniform(0.2, 1.5)
    phase = rng.uniform(0, 2 * np.pi, 2)
    return (amp * (np.sin(grid * rng.uniform(0.3, 0.9) + phase[0]) * 0.6 + np.cos(grid * rng.uniform(0.2, 0.5) + phase[1]) * 0.4)).astype(np.float32)


def main():
    binary = Path(sys.argv[1])
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
    rng = np.random.default_rng(11)
    count, start, step = 512, -16.0, 24.0 / 511
    grid = (start + step * np.arange(count)).astype(np.float64)
    cases, expected = [], []
    for _ in range(n):
        layers = []
        for _ in range(rng.integers(0, 4)):
            layers.append({"exposure": float(rng.choice([0.0, rng.uniform(-3, 3)])),
                           "local": random_table(rng, grid) if rng.random() < 0.6 else None,
                           "global": random_table(rng, grid) if rng.random() < 0.6 else None})
        panel = {"local": random_table(rng, grid) if rng.random() < 0.5 else None, "global": random_table(rng, grid) if rng.random() < 0.5 else None}
        x = float(rng.uniform(-9, 3))
        case = {"x": x, "xb": float(x + rng.uniform(-2.5, 2.5)), "E0": float(rng.choice([0.0, rng.uniform(-2, 2)])),
                "c": [float(rng.choice([0.0, 1.0, rng.random()])) for _ in layers], "layers": layers, "panel": panel}
        cases.append(case)
        # the Python port
        t = ArrayTables(grid)
        py_layers = [{"E": l["exposure"], "_L": l["local"], "_G": l["global"]} for l in layers]
        py_panel = {"E": case["E0"], "_L": panel["local"], "_G": panel["global"]}
        level = t.r5_level(np.array(case["x"]), np.array(case["xb"]), py_panel, py_layers, case["c"])
        e = case["E0"] + sum(c * l["exposure"] for c, l in zip(case["c"], layers))
        expected.append(float(level) - (case["x"] + e))
    serial = [{**c, "layers": [{**l, "local": None if l["local"] is None else [float(v) for v in l["local"]],
                                 "global": None if l["global"] is None else [float(v) for v in l["global"]]} for l in c["layers"]],
               "panel": {k: None if v is None else [float(w) for w in v] for k, v in c["panel"].items()}} for c in cases]
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "cases.json"
        path.write_text(json.dumps({"start": start, "step": step, "count": count, "cases": serial}))
        out = subprocess.run([str(binary), str(path)], capture_output=True, text=True, check=True).stdout.split("\n")
    swift = np.array([[float(v) for v in line.split()] for line in out if line.strip()])
    tone = swift[:, 1]
    diff = np.abs(tone - np.array(expected))
    print(f"{n} random cases (0 to 3 mask layers, panel tables, exposures, coverages 0 to 1)")
    print(f"tone gain in stops, Swift SceneCPU against the Python port: max |difference| {diff.max():.2e}, median {np.median(diff):.2e}")
    print(f"exposure in stops, Swift against the cases' sum: max |difference| {np.abs(swift[:, 0] - np.array([c['E0'] * 0 + sum(cc * l['exposure'] for cc, l in zip(c['c'], c['layers'])) for c in cases])).max():.2e}")
    ok = diff.max() < 1e-4
    print("PARITY" if ok else "MISMATCH")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
