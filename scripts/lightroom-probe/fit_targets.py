"""Lightroom's Basic tone controls as output-L* targets, and the tone base field's constants
(docs/research/lightroom-sliders.md).

From Lightroom's exports of the probe raw, one per control and value: for Contrast, Whites and
Blacks the change of each pixel's output L* against its L* in the unadjusted render, as a smooth
curve; for Highlights and Shadows the change at the local base, where the base is the tone base
field (`ToneBaseField`) of Argent's own decode of the raw. The base field's radius and epsilon are
searched for the base that best explains Lightroom's per-pixel change as a gain in stops applied
by base level. Writes Sources/ArgentCore/Film/LightroomToneTargets.swift and a JSON report.

    python -I scripts/lightroom-probe/fit_targets.py [--exports DIR] [--raw FILE] [--no-sweep]
                                                     [--swift FILE] [--report FILE]

Needs a release argent-spike (`swift build -c release --product argent-spike`) for the guide.
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe  # noqa: E402

RADII = [0.005, 0.0075, 0.01, 0.0125, 0.015, 0.02, 0.03, 0.05, 0.08]
EPSILONS = [0.25, 0.35, 0.5, 0.7, 1.0, 1.4, 2.0]
# Before this measurement (DESIGN.md), for comparison.
PROVISIONAL = (0.03, 0.25)
# Gain knots in stops against 0.18, a quarter stop apart.
KNOTS = np.arange(-8.0, 7.0001, 0.25)
SWEEP_VALUES = [-100, -50, 50, 100]
SWEEP_PIXELS = 400_000


class Scene:
    """The probe's Lightroom renders and Argent's guide, at the analysis resolution."""

    def __init__(self, exports, raw, stock, prefix="raw"):
        self.exports = Path(exports)
        self.prefix = prefix
        self.L0 = probe.lightroom_lstar(self.path(None, 0))
        Y = probe.guide(raw, stock)
        if Y.shape[0] // probe.BLOCK != self.L0.shape[0] or Y.shape[1] // probe.BLOCK != self.L0.shape[1]:
            raise SystemExit(f"guide {Y.shape} does not match the exports {self.L0.shape} x {probe.BLOCK}")
        self.base_field = probe.ToneBase(Y)
        # Scene stops against 0.18 of each analysis pixel's own light.
        self.offset = np.log2(0.18)
        self.x = np.log2(np.sqrt(probe.block_mean(Y).astype(np.float64) ** 2 + 1e-12)) - self.offset
        # Lightroom's transfer of this frame, away from clipped white and the black floor.
        self.valid = (self.L0 > 0.3) & (self.L0 < 99.0)
        self.transfer = probe.Transfer(self.x[self.valid], self.L0[self.valid])

    def path(self, control, value):
        stem = "00_base" if control is None else None
        if stem is None:
            index = probe.variants().index((control, value))
            stem = f"{index:02d}_{probe.variant_name(control, value)}"
        return self.exports / f"{self.prefix}_{stem}.tif"

    def delta(self, control, value):
        return probe.lightroom_lstar(self.path(control, value)) - self.L0

    def base(self, radius_fraction, epsilon, coefficient_share=probe.COEFFICIENT_SHARE):
        """Each analysis pixel's base, in stops against 0.18."""
        return self.base_field.base(self.x + self.offset, radius_fraction, epsilon, coefficient_share) - self.offset


def upper_bound(x, xb, dL):
    """R^2 of the mean change in 0.1 by 0.1 stop cells of (pixel, base): what any function of
    the two could explain."""
    i = np.clip(((x + 8) / 0.1).astype(int), 0, 159)
    j = np.clip(((xb + 8) / 0.1).astype(int), 0, 159)
    k = i * 160 + j
    n = np.bincount(k, minlength=160 * 160)
    s = np.bincount(k, dL, minlength=160 * 160)
    return probe.r_squared(dL, (s / np.maximum(n, 1))[k])


def sweep(scene, share):
    """R^2 of the gain-on-base model for each radius and epsilon, on a fixed subsample, the
    coefficient boxes `share` of the guide boxes' radius."""
    rng = np.random.default_rng(20261029)
    pick = rng.choice(np.flatnonzero(scene.valid.ravel()), SWEEP_PIXELS, replace=False)
    x = scene.x.ravel()[pick]
    deltas = {(c, v): scene.delta(c, v).ravel()[pick] for c in probe.LOCAL for v in SWEEP_VALUES}

    def score(xb):
        return {f"{c}{v:+d}": round(float(probe.r_squared(dL, probe.fit_gain(scene.transfer, x, xb, dL, KNOTS)[1])), 4)
                for (c, v), dL in deltas.items()}

    rows = []
    pixelwise = score(x)
    for rf in RADII:
        for eps in EPSILONS:
            r2 = score(scene.base(rf, eps, share).ravel()[pick])
            rows.append({"radiusFraction": rf, "epsilon": eps, "r2": r2, "mean": round(float(np.mean(list(r2.values()))), 4)})
            print(f"  radius {rf:.4f} epsilon {eps:4.2f}  mean R^2 {rows[-1]['mean']:.4f}", flush=True)
    best = max(rows, key=lambda r: r["mean"])
    provisional = score(scene.base(*PROVISIONAL, share).ravel()[pick])
    xb = scene.base(best["radiusFraction"], best["epsilon"], share).ravel()[pick]
    base_only = {}
    for (c, v), dL in deltas.items():
        centres, medians, _ = probe.binned_median(xb, dL, np.arange(-8, 7.001, 0.05), minimum=1)
        base_only[f"{c}{v:+d}"] = round(float(probe.r_squared(dL, np.interp(xb, centres, medians))), 4)
    return {
        "pixels": SWEEP_PIXELS,
        "coefficientShare": share,
        "grid": rows,
        "best": {"radiusFraction": best["radiusFraction"], "epsilon": best["epsilon"], "r2": best["r2"], "mean": best["mean"]},
        "pixelwise": {"r2": pixelwise, "mean": round(float(np.mean(list(pixelwise.values()))), 4)},
        "provisional": {"radiusFraction": PROVISIONAL[0], "epsilon": PROVISIONAL[1], "r2": provisional,
                        "mean": round(float(np.mean(list(provisional.values()))), 4)},
        "baseOnly": base_only,
        "upperBound": {f"{c}{v:+d}": round(float(upper_bound(x, xb, dL)), 4) for (c, v), dL in deltas.items()},
    }


def global_target(L0, dL):
    """A global control's change on the lightness grid: medians in 1-L* bins of the unadjusted
    L*, lightly smoothed, black and white held where Lightroom holds them, and the mapping kept
    increasing."""
    centres, medians, counts = probe.binned_median(L0.ravel(), dL.ravel(), np.arange(0, 100.001, 1.0), minimum=30)
    smooth = probe.whittaker(medians, np.minimum(counts, 2000).astype(float), 20.0)
    fine = np.arange(0, 100.0001, 0.25)
    change = np.interp(fine, centres, smooth)
    # Black stays black unless the control lifts it: then the frame's darkest pixels' change
    # (Blacks +100 lifts those under L* 0.5 by 7). White stays white (on the raw, and on the
    # chart's ramp for every global control).
    darkest = dL[L0 < 0.5]
    change[0] = max(0.0, float(np.median(darkest))) if darkest.size >= 30 else max(0.0, smooth[0])
    change[-1] = 0.0
    out = np.clip(fine + change, 0, 100)
    out = np.maximum.accumulate(out + fine * 1e-6) - fine * 1e-6
    return np.interp(probe.LIGHTNESS, fine, out - fine), {"bins": len(centres), "pixels": int(counts.sum())}


def local_target(scene, dL, xb, value):
    """A local control's change at the base's own L* on the lightness grid, from the gain in stops
    fitted by base level: transfer(xb + gain(xb)) - transfer(xb) at xb = transfer^-1(L*)."""
    valid = scene.valid
    x, b = scene.x[valid], xb[valid]
    lo, hi = np.percentile(b, [0.05, 99.95])
    knots = KNOTS[(KNOTS >= np.floor(lo * 4) / 4) & (KNOTS <= np.ceil(hi * 4) / 4)]
    gains, predicted = probe.fit_gain(scene.transfer, x, b, dL[valid], knots)
    r2 = probe.r_squared(dL[valid], predicted)
    # On a fine grid of base L*, smoothed where few pixels have their base (above L* 84 a few
    # hundred per bin), and of the value's sign: Lightroom's local change never reverses.
    fine = np.arange(0.25, 100, 0.5)
    at = scene.transfer.inverse(fine)
    change = scene.transfer(at + np.interp(at, knots, gains)) - fine
    counts = np.bincount(np.clip((scene.transfer(b) / 0.5).astype(int), 0, len(fine) - 1), minlength=len(fine))
    weights = np.minimum(counts, 2000) + 20.0
    # White: the change of clipped pixels whose base is clipped too, the sky's, within 0...100;
    # it anchors the curve's top, where few bases lie.
    sky = (scene.L0 >= 99.8) & (scene.transfer(xb) >= 98.5)
    white = float(np.clip(np.median(dL[sky]), -100, 0)) if sky.sum() >= 200 else 0.0
    change[-1], weights[-1] = white, 2000.0
    change = probe.whittaker(change, weights, 2e6)
    change = np.maximum(change, 0) if value > 0 else np.minimum(change, 0)
    out = np.maximum.accumulate(np.clip(fine + change, 0, 100))
    change = out - fine
    L = probe.LIGHTNESS
    row = np.interp(L, fine, change)
    row[0], row[-1] = 0.0, white
    return row, {"r2": round(float(r2), 4), "knots": [float(knots[0]), float(knots[-1])],
                 "gainStops": {f"{k:+.2f}": round(float(g), 3) for k, g in zip(knots, gains)}}


def peak(row):
    i = int(np.argmax(np.abs(row)))
    return {"change": round(float(row[i]), 2), "at": float(probe.LIGHTNESS[i])}


def linearity(rows):
    """Each value's peak change as a share of the same-signed 100's, and the exponent p with
    peak(v) = peak(100) (|v|/100)^p fitted over 25 and 50."""
    out = {}
    for sign in (-1, 1):
        full = np.abs(rows[sign * 100]).max()
        shares = {v: float(np.abs(rows[sign * v]).max() / full) if full > 0 else 0.0 for v in (25, 50)}
        p = np.mean([np.log(max(shares[v], 1e-6)) / np.log(v / 100) for v in (25, 50)])
        out["negative" if sign < 0 else "positive"] = {"share25": round(shares[25], 3), "share50": round(shares[50], 3),
                                                       "exponent": round(float(p), 2)}
    return out


def swift_rows(rows):
    def row(values):
        return "[" + ", ".join(f"{v:.2f}".rstrip("0").rstrip(".") if abs(v) >= 0.005 else "0" for v in values) + "]"
    return "[\n" + ",\n".join(f"        {row(rows[v])}" for v in probe.VALUES) + ",\n    ]"


def write_swift(path, targets, source):
    values = [f"{v:g}" for v in probe.LIGHTNESS]
    grid = ",\n        ".join(", ".join(values[i:i + 14]) for i in range(0, len(values), 14))
    body = f"""// Generated by scripts/lightroom-probe/fit_targets.py; do not edit by hand.
/// Lightroom Classic's Basic tone controls as changes of output CIE L*: Lightroom Classic 15.6,
/// process version 15.4, Adobe Standard, measured on one raw (`source`; docs/research/lightroom-sliders.md).
/// Contrast, Whites and Blacks are global: the change of a pixel's output L* by its unadjusted
/// output L*. Highlights and Shadows are local: the change at the local base's L*, the base being
/// the tone base field of the frame's log luminance.
public enum LightroomToneTargets {{
    public static let source = "{source}"
    /// Output L* (for Highlights and Shadows: the local base's L*) where changes are given;
    /// ascending, first 0 and last 100.
    public static let lightness: [Float] = [
        {grid},
    ]
    /// Control values with a row; value 0 is implicit and changes nothing.
    public static let values: [Float] = [{", ".join(str(v) for v in probe.VALUES)}]
    /// Output L* change, [value row][lightness column].
    public static let contrast: [[Float]] = {swift_rows(targets["contrast"])}
    public static let highlights: [[Float]] = {swift_rows(targets["highlights"])}
    public static let shadows: [[Float]] = {swift_rows(targets["shadows"])}
    public static let whites: [[Float]] = {swift_rows(targets["whites"])}
    public static let blacks: [[Float]] = {swift_rows(targets["blacks"])}
}}
"""
    Path(path).write_text(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--exports", default=probe.DATA / "exports")
    parser.add_argument("--raw", default=probe.DATA / "raw" / "raw_00_base.ARW")
    parser.add_argument("--stock", default=probe.ROOT / "build" / "stocks" / "kodak-portra-400",
                        help="any baked stock; the guide is the decode before the film model")
    parser.add_argument("--no-sweep", action="store_true", help="use --radius and --epsilon as given")
    parser.add_argument("--radius", type=float, default=probe.RADIUS_FRACTION)
    parser.add_argument("--epsilon", type=float, default=probe.EPSILON)
    parser.add_argument("--coefficient-share", type=float, default=probe.COEFFICIENT_SHARE,
                        help="the coefficient boxes' radius as a share of the guide boxes' (default: the compiler's)")
    parser.add_argument("--swift", default=probe.ROOT / "Sources" / "ArgentCore" / "Film" / "LightroomToneTargets.swift")
    parser.add_argument("--report", default=probe.DATA / "fit" / "report.json")
    args = parser.parse_args()

    start = time.time()
    scene = Scene(args.exports, args.raw, args.stock)
    report = {"exports": str(args.exports), "raw": str(args.raw), "analysis": list(scene.L0.shape),
              "transfer": {f"{x:+.1f}": round(float(scene.transfer(x)), 2) for x in np.arange(-5, 5.01, 0.5)}}
    if args.no_sweep:
        rf, eps = args.radius, args.epsilon
    else:
        print("sweeping the base field's radius and epsilon", flush=True)
        report["sweep"] = sweep(scene, args.coefficient_share)
        rf, eps = report["sweep"]["best"]["radiusFraction"], report["sweep"]["best"]["epsilon"]
    share = args.coefficient_share
    report["baseField"] = {"radiusFraction": rf, "epsilon": eps, "fieldLongSide": probe.FIELD_LONG_SIDE,
                           "coefficientShare": share}
    xb = scene.base(rf, eps, share)

    targets, details = {}, {}
    for control in probe.CONTROLS:
        targets[control], details[control] = {}, {}
        for value in probe.VALUES:
            dL = scene.delta(control, value)
            if control in probe.GLOBAL:
                row, info = global_target(scene.L0, dL)
            else:
                row, info = local_target(scene, dL, xb, value)
            info["peak"] = peak(row)
            targets[control][value] = row
            details[control][value] = info
            print(f"{control:10s} {value:+4d}  peak {info['peak']['change']:+6.2f} at L* {info['peak']['at']:5.1f}"
                  + (f"  R^2 {info['r2']:.3f}" if "r2" in info else ""), flush=True)
        details[control]["linearity"] = linearity(targets[control])
    report["targets"] = {c: {str(v): [round(float(t), 3) for t in targets[c][v]] for v in probe.VALUES} for c in probe.CONTROLS}
    report["lightness"] = probe.LIGHTNESS.tolist()
    report["details"] = {c: {str(k): v for k, v in d.items()} for c, d in details.items()}

    source = (f"Lightroom Classic 15.6, PV 15.4, Adobe Standard, one a7 IV raw (DSC06674); "
              f"local base radiusFraction {rf:g}, epsilon {eps:g}"
              + (f", coefficient boxes {share:g} of the radius" if share != 1 else ""))
    write_swift(args.swift, targets, source)
    Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    Path(args.report).write_text(json.dumps(report, indent=1))
    print(f"wrote {args.swift} and {args.report} in {time.time() - start:.0f} s")


if __name__ == "__main__":
    main()
