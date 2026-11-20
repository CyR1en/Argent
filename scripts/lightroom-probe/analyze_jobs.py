"""What the Lightroom jobs show (docs/research/lightroom-sliders.md, sections 4 and 5).

    python -I analyze_jobs.py adaptation   the same ramp over six contents: the change at each level,
                                           and whether it varies with distance from the content
    python -I analyze_jobs.py locality     squares 8 to 512 pixels on dark, mid and bright surrounds
    python -I analyze_jobs.py scenes       three more a7 IV scenes against the probe's targets, with
                                           Whites +100's reach and Contrast's pivot by scene
    python -I analyze_jobs.py combos       composition orders, and each control under Exposure +/-1
    python -I analyze_jobs.py range        a range weight on the base, against the raw's local fit

The plug-in's raw renders carry Lightroom's default Adobe Color look (a LookTable and tone curve
over Adobe Standard); the probe's own renders, made from XMP sidecars, do not. `combos` maps the
probe's single-control renders through the look's global L* map (measured from the two base
renders, residual 0.08 L*) before comparing; the scenes are compared as they are.
"""
import glob
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe  # noqa: E402
from fit_targets import KNOTS, Scene, global_target, local_target  # noqa: E402

D = probe.DATA
STOCK = probe.ROOT / "build" / "stocks" / "kodak-portra-400"
CORPUS = probe.ROOT / "references" / "corpus" / "imaging-resource-a7iv-gallery"
SCENES = ["Y-JG-SONY-A7-IV-0602", "Y-JG-SONY-A7-IV-1455", "Y-JG-SONY-A7-IV-0255"]
CONTENTS = ["dark", "mid", "bright", "white", "split", "texture"]
RADIUS, EPSILON = probe.RADIUS_FRACTION, probe.EPSILON


def export(folder, name, control):
    return glob.glob(str(D / folder / f"{name}_*_{control}.tif"))[0]


def ramp_stops(width):
    return -12 * (1 - (np.arange(width) + 0.5) / width)


def adaptation():
    levels = [-10, -8, -6, -5, -4, -3, -2, -1, -0.5]
    base = {c: probe.lightroom_luminance(D / f"exports-adapt-{c}" / f"adapt-{c}_00_base.tif")[:400] for c in CONTENTS}
    s = ramp_stops(base["mid"].shape[1])
    print("change of L* on the ramp (rows 30-200) at stops under white; then the spread over rows 5-395 at -2 stops")
    print("            " + " ".join(f"{v:+6.1f}" for v in levels))
    for control in ["highlights_-100", "highlights_+100", "shadows_+100", "shadows_-100", "whites_+100", "whites_-100",
                    "blacks_+100", "blacks_-100", "contrast_+100", "contrast_-100"]:
        print(control)
        for c in CONTENTS:
            Y = probe.lightroom_luminance(export(f"exports-adapt-{c}", f"adapt-{c}", control))[:400]
            dl = probe.lstar(Y) - probe.lstar(base[c])
            row = dl[30:200].mean(0)
            col = int(np.argmin(np.abs(s + 2)))
            spread = dl[5:396, col].max() - dl[5:396, col].min()
            print(f"  {c:8s}  " + " ".join(f"{np.interp(v, s, row):+6.1f}" for v in levels) + f"   rows {spread:4.1f}")


def locality():
    layout = json.loads((D / "charts-dng" / "locality-layout.json").read_text())
    B = probe.lightroom_luminance(D / "exports-locality" / "locality_00_base.tif")

    def centre(Y, box):
        x0, y0, x1, y1 = box
        m = max(1, (x1 - x0) // 4)
        cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
        return Y[cy - m:cy + m, cx - m:cx + m].mean()

    for control in ["highlights_-100", "highlights_+100", "shadows_+100", "shadows_-100", "whites_+100", "contrast_+100"]:
        V = probe.lightroom_luminance(export("exports-locality", "locality", control))
        print(control, "(change of each square's centre by its size; the ramp at the same level)")
        s = ramp_stops(B.shape[1])
        r0, r1 = layout["ramp"]["band"]
        ramp = probe.lstar(V[r0 + 30:r1 - 30].mean(0)) - probe.lstar(B[r0 + 30:r1 - 30].mean(0))
        for row in layout["rows"]:
            squares = [q for q in layout["squares"] if q["row"] == row["name"]]
            b0 = row["band"][0]
            surround = probe.lstar(V[b0 + 20:b0 + 60, 20:200].mean()) - probe.lstar(B[b0 + 20:b0 + 60, 20:200].mean())
            cells = " ".join(f"{q['size']}:{probe.lstar(centre(V, q['box'])) - probe.lstar(centre(B, q['box'])):+5.1f}" for q in squares)
            print(f"  {row['name']:15s} surround {surround:+5.1f} | squares {cells} | ramp {np.interp(row['stops'], s, ramp):+5.1f}")


def scenes():
    report = json.loads((D / "fit" / "report.json").read_text())
    L = probe.LIGHTNESS
    probe_scene = Scene(D / "exports", D / "raw" / "raw_00_base.ARW", STOCK)
    for name, scene in [("probe", probe_scene)] + [(f[-4:], Scene(D / f"exports-scene-{f}", CORPUS / f"{f}.ARW", STOCK,
                                                                   prefix=f"scene-{f}")) for f in SCENES]:
        xb = scene.base(RADIUS, EPSILON)
        p90, p99, median = np.percentile(scene.L0, [90, 99, 50])
        whites = global_target(scene.L0, scene.delta("whites", 100))[0]
        contrast = global_target(scene.L0, scene.delta("contrast", 100))[0]
        mid = (L > 20) & (L < 90)
        pivot = np.interp(0, contrast[mid], L[mid])
        print(f"{name}: median L* {median:.1f}, p90 {p90:.1f}, p99 {p99:.1f}; Whites +100 sends p90 to "
              f"{p90 + np.interp(p90, L, whites):.1f} and p99 to {p99 + np.interp(p99, L, whites):.1f}; Contrast +100 pivots at L* {pivot:.1f}")
        if name == "probe":
            continue
        for control in probe.CONTROLS:
            cells = []
            for value in (-100, -50, 50, 100):
                dL = scene.delta(control, value)
                row = global_target(scene.L0, dL)[0] if control in probe.GLOBAL else local_target(scene, dL, xb, value)[0]
                ref = np.array(report["targets"][control][str(value)])
                by = scene.L0 if control in probe.GLOBAL else scene.transfer(xb)
                c, _, _ = probe.binned_median(by.ravel(), dL.ravel(), np.arange(0, 100.001, 2.5), minimum=300)
                have = np.array([np.any(np.abs(c - v) <= 1.25 + 1e-6) for v in L]) & (L > 2) & (L < 98)
                i = int(np.argmax(np.abs(row)))
                cells.append(f"{value:+4d} peak {row[i]:+5.1f}@{L[i]:4.1f} rmse {np.sqrt(np.mean((row - ref)[have] ** 2)):4.1f}")
            print(f"  {control:10s} " + " | ".join(cells))


def combos():
    E = D / "exports-combos"
    scene = Scene(D / "exports", D / "raw" / "raw_00_base.ARW", STOCK)
    standard = scene.L0
    base = probe.lightroom_lstar(E / "combos_00_base.tif")
    c, m, _ = probe.binned_median(standard.ravel(), base.ravel(), np.arange(0, 100.001, 0.5), minimum=20)

    def look(L):
        return np.interp(L, c, m)

    print(f"Adobe Color look as a global L* map: residual {np.sqrt(np.mean((look(standard) - base) ** 2)):.2f}")
    valid = (standard > 1) & (standard < 99)

    def single(control, value):
        return look(probe.lightroom_lstar(scene.path(control, value)))

    def combo(label):
        return probe.lightroom_lstar(E / f"combos_{label}.tif")

    def mapping(before, after):
        cc, mm, _ = probe.binned_median(before.ravel(), after.ravel(), np.arange(0, 100.001, 1.0), minimum=20)
        return lambda L: np.interp(L, cc, mm)

    def rmse(predicted, observed):
        r = (observed - predicted)[valid]
        return f"{np.sqrt(np.mean(r ** 2)):.2f} (mean {r.mean():+.2f})"

    for label, (a, va), (b, vb) in [("wh+50_bl-50", ("whites", 50), ("blacks", -50)), ("wh-50_bl+50", ("whites", -50), ("blacks", 50)),
                                     ("co+50_wh+50", ("whites", 50), ("contrast", 50)), ("co+50_bl-50", ("blacks", -50), ("contrast", 50))]:
        A, B, O = single(a, va), single(b, vb), combo(label)
        fa, fb = mapping(base, A), mapping(base, B)
        print(f"{label}: {a} then {b} {rmse(fb(fa(base)), O)}; {b} then {a} {rmse(fa(fb(base)), O)}; "
              f"sum {rmse(A + B - base, O)}")
    for label, (a, va), (b, vb) in [("hl-100_sh+100", ("highlights", -100), ("shadows", 100)),
                                     ("hl+100_sh-100", ("highlights", 100), ("shadows", -100)),
                                     ("co+50_hl-50", ("highlights", -50), ("contrast", 50)),
                                     ("co-50_sh+50", ("shadows", 50), ("contrast", -50))]:
        A, B, O = single(a, va), single(b, vb), combo(label)
        line = f"{label}: sum of changes {rmse(A + B - base, O)}"
        if b == "contrast":
            fb = mapping(base, B)
            line += f"; local then global {rmse(fb(A), O)}; global then local {rmse(fb(base) + A - base, O)}"
        print(line)
    xb = scene.base(RADIUS, EPSILON)
    for label, ev, (control, value) in [("ex-1_hl-100", -1, ("highlights", -100)), ("ex+1_hl-100", 1, ("highlights", -100)),
                                        ("ex-1_sh+100", -1, ("shadows", 100)), ("ex+1_sh+100", 1, ("shadows", 100)),
                                        ("ex-1_wh+100", -1, ("whites", 100)), ("ex+1_bl-100", 1, ("blacks", -100))]:
        exposed = single("exposure", float(ev))
        d0, dE = single(control, value) - base, combo(label) - exposed
        local = control in probe.LOCAL
        keep = (exposed > 1) & (exposed < 99) & valid
        by0 = probe.Transfer(scene.x[valid], base[valid])(xb) if local else base
        byE = probe.Transfer(scene.x[keep], exposed[keep])(xb) if local else exposed
        edges = np.arange(0, 100.001, 5)
        c0, m0, _ = probe.binned_median(by0.ravel(), d0.ravel(), edges, minimum=200)
        cE, mE, _ = probe.binned_median(byE.ravel(), dE.ravel(), edges, minimum=200)
        both = sorted(set(c0) & set(cE))
        print(f"{label}: change by {'base ' if local else ''}output L* at EV 0 / EV {ev:+d}: "
              + " ".join(f"{k:g}:{m0[list(c0).index(k)]:+.1f}/{mE[list(cE).index(k)]:+.1f}" for k in both))


def range_weight():
    scene = Scene(D / "exports", D / "raw" / "raw_00_base.ARW", STOCK)
    pick = np.random.default_rng(20261029).choice(np.flatnonzero(scene.valid.ravel()), 400_000, replace=False)
    x = scene.x.ravel()[pick]
    deltas = [scene.delta(c, v).ravel()[pick] for c in probe.LOCAL for v in (-100, -50, 50, 100)]
    xb0 = scene.base(RADIUS, EPSILON).ravel()[pick]
    for sigma in [0.75, 1.0, 1.5, 2.0, 3.0, None]:
        d = x - xb0
        xb = xb0 if sigma is None else x - d * np.exp(-d * d / (2 * sigma * sigma))
        r2 = np.mean([probe.r_squared(dL, probe.fit_gain(scene.transfer, x, xb, dL, KNOTS)[1]) for dL in deltas])
        print(f"range sigma {sigma if sigma else 'none':>4} stops: mean R^2 {r2:.4f}")


if __name__ == "__main__":
    commands = {"adaptation": adaptation, "locality": locality, "scenes": scenes, "combos": combos, "range": range_weight}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        raise SystemExit(__doc__)
    commands[sys.argv[1]]()
