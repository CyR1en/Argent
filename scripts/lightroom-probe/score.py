"""How close Argent's Light controls come to Lightroom's on the probe raw (docs/research/lightroom-sliders.md).

Renders the probe raw through argent-spike at every value Lightroom was measured at, as the app
develops it (`--auto`: the frame's automatic aim, the manual reference at its level), and compares
each control's change of output L* with Lightroom's, measured the same way on both sides:

- Contrast, Whites, Blacks and Exposure by the pixel's own L* in the unadjusted render;
- Highlights and Shadows by the L* of the pixel's local base (the tone base field of the frame's
  own decode; each render's own transfer from scene stops to L* gives the base its L*).

Per control and value: the curves' RMSE and largest difference over 2.5-L* bins, leakage (Argent's
mean |change| in the bins where Lightroom changes less than 1 L*), a named reach check, and the
per-pixel RMSE of the two change maps (the renders lie pixel on pixel). Every render here has one
control set, so 2026-10-29-1 and 2026-11-06-1, which differ only where Highlights or Shadows is set
with Exposure, score the same bytes (research/lightroom-sliders.md, section 12). Lens corrections are off
in these renders so the pictures register with Lightroom's export; nothing else differs from the
app's render bar halation, grain and sharpening, which are off.

    python -I scripts/lightroom-probe/score.py [--stock DIR]... [--manual-version V] [--spike BIN]
                                               [--label NAME] [--fresh]

Writes DATA/score/<label>/scorecard.md and scorecard.json.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe  # noqa: E402

# The tone base field's constants: the gain-table compilers' (probe.py), fitted by fit_targets.py.
RADIUS_FRACTION = probe.RADIUS_FRACTION
EPSILON = probe.EPSILON
COEFFICIENT_SHARE = probe.COEFFICIENT_SHARE
BINS = np.arange(0, 100.001, 2.5)
STOCKS = ["kodak-portra-400", "kodak-ektar-100"]
NAMES = {"kodak-portra-400": "Portra 400", "kodak-ektar-100": "Ektar 100"}
FLAG = {"exposure": "--exposure-ev", "contrast": "--contrast", "highlights": "--highlights",
        "shadows": "--shadows", "whites": "--whites", "blacks": "--blacks"}


def reach(control, value, base_L, dL):
    """The named check: what each control does where Lightroom's leaves the picture alone, or how
    far into the midtones it reaches."""
    if control == "highlights":
        m = base_L < 40
        return "mean below L*40", float(np.mean(dL[m])) if m.any() else float("nan")
    if control == "shadows":
        m = base_L > 70
        return "mean above L*70", float(np.mean(dL[m])) if m.any() else float("nan")
    if control in ("whites", "blacks", "contrast"):
        m = (base_L >= 47.5) & (base_L < 52.5)
        return "at L*50", float(np.median(dL[m])) if m.any() else float("nan")
    m = (base_L >= 45) & (base_L < 55)
    return "at L*50", float(np.median(dL[m])) if m.any() else float("nan")


def curve(base_L, dL):
    c, m, n = probe.binned_median(base_L.ravel(), dL.ravel(), BINS, minimum=200)
    return dict(zip(np.round(c, 2).tolist(), m.tolist()))


class Side:
    """One renderer's unadjusted L*, its transfer, and its changes, at the analysis resolution."""

    def __init__(self, L0, x, xb):
        self.L0 = L0
        valid = (L0 > 0.3) & (L0 < 99.0)
        self.transfer = probe.Transfer(x[valid], L0[valid])
        self.base_L = self.transfer(xb)

    def by(self, control):
        return self.base_L if control in probe.LOCAL else self.L0


def render(raw, stock, out, flags, spike_binary, manual_version):
    if not (out / (Path(raw).stem + ".tif")).exists():
        extra = ["--manual-version", manual_version] if manual_version else []
        probe.spike(raw, out, stock, "--auto", "--tiff", "--no-lens", "--long-edge", 1752, *extra, *flags,
                    binary=spike_binary)
    return probe.lstar(probe.srgb_luminance(out / (Path(raw).stem + ".tif")).astype(np.float64))


def score_stock(stock, lightroom, x, xb, raw, work, spike_binary, manual_version):
    work.mkdir(parents=True, exist_ok=True)
    L0 = render(raw, stock, work / "base", [], spike_binary, manual_version)
    if L0.shape != lightroom.L0.shape:
        raise SystemExit(f"Argent's render {L0.shape} does not match Lightroom's {lightroom.L0.shape}")
    argent = Side(L0, x, xb)
    rows = []
    for control, value in probe.variants()[1:]:
        name = probe.variant_name(control, value)
        flags = [FLAG[control], value]
        dA = render(raw, stock, work / name, flags, spike_binary, manual_version) - L0
        dL = probe.lightroom_lstar(lightroom.path(control, value)) - lightroom.L0
        ca, cl = curve(argent.by(control), dA), curve(lightroom.by(control), dL)
        common = sorted(set(ca) & set(cl))
        diff = np.array([ca[k] - cl[k] for k in common])
        worst = int(np.argmax(np.abs(diff)))
        quiet = [k for k in common if abs(cl[k]) < 1]
        label, a_reach = reach(control, value, argent.by(control), dA)
        _, l_reach = reach(control, value, lightroom.by(control), dL)
        a, b = argent.by(control), lightroom.by(control)
        both = (a > 0.5) & (a < 99.5) & (b > 0.5) & (b < 99.5)
        rows.append({
            "control": control, "value": value,
            "rmse": float(np.sqrt(np.mean(diff ** 2))), "max": float(diff[worst]), "maxAt": common[worst],
            "leak": float(np.mean([abs(ca[k]) for k in quiet])) if quiet else float("nan"),
            "leakBins": len(quiet), "reach": label, "reachArgent": a_reach, "reachLightroom": l_reach,
            "pixelRMSE": float(np.sqrt(np.mean((dA - dL)[both] ** 2))),
            "argent": ca, "lightroom": cl,
        })
        print(f"  {name:16s} rmse {rows[-1]['rmse']:5.2f}  max {rows[-1]['max']:+6.2f} at L*{rows[-1]['maxAt']:5.1f}  "
              f"leak {rows[-1]['leak']:5.2f}  {label} {a_reach:+6.2f} / {l_reach:+6.2f}  pixel {rows[-1]['pixelRMSE']:5.2f}",
              flush=True)
    return rows


def markdown(results, meta):
    lines = [f"# Argent against Lightroom: {meta['label']}", "",
             f"Manual compiler {meta['manualVersion']}; spike {meta['spike']} ({meta['commit']}); "
             f"base field radiusFraction {RADIUS_FRACTION}, epsilon {EPSILON}, coefficient boxes {COEFFICIENT_SHARE:g} "
             f"of the radius, linear-light guide; {meta['date']}.", "",
             "Changes of output L*. RMSE and max: Argent's curve less Lightroom's over 2.5-L* bins (by the "
             "pixel's unadjusted L*, for Highlights and Shadows by its local base's L*). Leak: Argent's mean "
             "|change| where Lightroom's is under 1 L*. Reach: the named check, Argent / Lightroom. Pixel: "
             "RMSE of the two change maps.", ""]
    for stock, rows in results.items():
        lines += [f"## {NAMES.get(stock, stock)} ({stock})", "",
                  "| Control | Value | RMSE | Max (at L*) | Leak | Reach | Argent / Lightroom | Pixel |",
                  "| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |"]
        for r in rows:
            value = f"{r['value']:+.1f} EV" if r["control"] == "exposure" else f"{r['value']:+d}"
            lines.append(f"| {r['control'].title()} | {value} | {r['rmse']:.2f} | {r['max']:+.2f} ({r['maxAt']:g}) | "
                         f"{r['leak']:.2f} | {r['reach']} | {r['reachArgent']:+.2f} / {r['reachLightroom']:+.2f} | "
                         f"{r['pixelRMSE']:.2f} |")
        lines += ["", "| Control | Mean RMSE | Mean leak | Mean pixel RMSE |", "| --- | ---: | ---: | ---: |"]
        for control in ["exposure"] + probe.CONTROLS:
            part = [r for r in rows if r["control"] == control]
            lines.append(f"| {control.title()} | {np.mean([r['rmse'] for r in part]):.2f} | "
                         f"{np.nanmean([r['leak'] for r in part]):.2f} | {np.mean([r['pixelRMSE'] for r in part]):.2f} |")
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stock", action="append", help="a stock id under build/stocks or a stock folder (default: "
                        + " and ".join(STOCKS) + ")")
    parser.add_argument("--manual-version", help="the manual compiler to render with (default: the spike's current)")
    parser.add_argument("--spike", default=probe.ROOT / ".build" / "release" / "argent-spike")
    parser.add_argument("--exports", default=probe.DATA / "exports")
    parser.add_argument("--raw", default=probe.DATA / "raw" / "raw_00_base.ARW")
    parser.add_argument("--label", help="the work folder's name under DATA/score (default: the manual version or 'current')")
    parser.add_argument("--fresh", action="store_true", help="render again even where renders exist")
    args = parser.parse_args()

    stocks = [Path(s) if os.sep in s else probe.ROOT / "build" / "stocks" / s for s in (args.stock or STOCKS)]
    label = args.label or args.manual_version or "current"
    work = probe.DATA / "score" / label
    if args.fresh and work.exists():
        subprocess.run(["rm", "-rf", str(work)], check=True)
    start = time.time()

    from fit_targets import Scene
    scene = Scene(args.exports, args.raw, stocks[0])
    xb = scene.base(RADIUS_FRACTION, EPSILON, COEFFICIENT_SHARE)
    lightroom = Side(scene.L0, scene.x, xb)
    lightroom.path = scene.path

    results = {}
    for stock in stocks:
        print(f"{NAMES.get(stock.name, stock.name)}: rendering and comparing", flush=True)
        results[stock.name] = score_stock(stock, lightroom, scene.x, xb, args.raw, work / stock.name,
                                          args.spike, args.manual_version)
    commit = subprocess.run(["git", "-C", str(probe.ROOT), "rev-parse", "--short", "HEAD"], capture_output=True,
                            text=True).stdout.strip()
    meta = {"label": label, "manualVersion": args.manual_version or "current (the spike's default)",
            "spike": str(args.spike), "commit": commit, "date": time.strftime("%Y-%m-%d"),
            "radiusFraction": RADIUS_FRACTION, "epsilon": EPSILON, "coefficientShare": COEFFICIENT_SHARE}
    (work / "scorecard.md").write_text(markdown(results, meta))
    (work / "scorecard.json").write_text(json.dumps({"meta": meta, "results": results}, indent=1))
    print(f"wrote {work / 'scorecard.md'} in {time.time() - start:.0f} s")


if __name__ == "__main__":
    main()
