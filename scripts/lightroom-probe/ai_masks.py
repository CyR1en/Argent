"""L2: Lightroom's AI masks, for the blind A/B (MODE masks-ai in Probe.lua; docs/masking-plan.md section 9, SESSION.md).

    python -I ai_masks.py job --root ROOT --frames frames.json --raws DIR
        Clones each frame into ROOT/inputs/ and writes ROOT/jobs/l2.job: an AI item (KIND=sky or subject) per frame in frames.json,
        and the known-gradient items (KIND=table) that validate the recovery. Needs ROOT/jobs/READY, as every job does.
    python -I ai_masks.py recover ROOT OUTDIR
        The mask of every photo in ROOT/exports/: OUTDIR/<photo>.npy, float32, coverage 0...1, top row first, and a one-line record of
        each in OUTDIR/recover.txt. Local Exposure scales with the coverage (L1: bit-exact), so at each pixel the masked export is
        placed between the base and the full-coverage series at fractions f of the mask's Exposure, in log luminance; the coverage is
        the fraction that reproduces it. Two series are measured and blended by the base luminance: -1 EV for the shadows, -4 EV for
        the highlights (SERIES). Pixels with no signal in either take the coverage of their neighbours.
    python -I ai_masks.py validate ROOT
        The recovered masks of the known-gradient items against their law (Linear profile, docs/provenance.md: cosine step,
        a -0.046, b 0.971, t in pixels perpendicular to the line): the error, overall and by the pixel's base luminance.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import masks_plan  # noqa: E402
import probe  # noqa: E402

CATALOG_GUARD = masks_plan.CATALOG_GUARD
# The two series: -1 EV reads the shadows, whose response at -4 EV clips to black; -4 EV reads a bright sky, which at -1 EV barely moves (the highlight shoulder).
SERIES = ((-1.0, (0.25, 0.5, 0.75, 1.0)), (-4.0, (0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0)))
BLEND = (0.02, 0.045)  # base luminance: the -1 EV series below the first, the -4 EV series above the second, a linear ramp between
GAMMA = 461 / 256  # the rTRC of Lightroom's ProPhoto TIFF exports (probe.lightroom_luminance reads the same from the ICC)
# Validating gradients: which frame, which line (Full point, Zero point), in the picture's normalized coordinates.
VALIDATION = {"val-vertical": ("DSC04060", (0.5, 0.15), (0.5, 0.85)), "val-horizontal": ("DSC04087", (0.15, 0.5), (0.85, 0.5))}
LINEAR_A, LINEAR_B = -0.046, 0.971  # the Linear profile's cosine step (docs/provenance.md)


def write_job(root, frames, raws):
    """Clones the frames and writes the job: every frame's AI item, then the known gradients."""
    root = Path(root)
    jobs = root / "jobs"
    if not (jobs / "READY").exists():
        raise SystemExit(f"{jobs}/READY is missing: the plug-in is not taking jobs")
    inputs = root / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    tables = root / "tables"
    tables.mkdir(parents=True, exist_ok=True)
    data = json.loads(Path(frames).read_text())
    lines = [f"CATALOG\t{CATALOG_GUARD}", "MODE\tmasks-ai", f"OUT\t{root / 'exports'}", "SETTLE\t3"]
    lines += [f"SERIES\t{e:g}\t" + ",".join(f"{f:g}" for f in fractions) for e, fractions in SERIES]
    raws = Path(raws)

    def clone(name, target):
        out = inputs / f"{target}.arw"
        if not out.exists():
            subprocess.run(["cp", "-c", str(raws / f"{name}.ARW"), str(out)], check=True)
        return out

    for kind in ("sky", "subject"):
        for name in data[kind]:
            lines.append(f"ITEM\t{clone(name, f'{kind}-{name}')}\tKIND={kind}")
    for label, (name, full, zero) in VALIDATION.items():
        corrections = [masks_plan.correction({"E": SERIES[0][0]}, [masks_plan.linear(full, zero)], name=label)]
        table = tables / f"{label}.json"
        table.write_text(json.dumps(corrections))
        lines.append(f"ITEM\t{clone(name, label)}\tKIND=table\t{table}")
    tmp = jobs / "l2.job.tmp"
    tmp.write_text("\n".join(lines) + "\n")
    tmp.rename(jobs / "l2.job")
    print(f"wrote {jobs / 'l2.job'}: {sum(line.startswith('ITEM') for line in lines)} items")


def luminance(path):
    img, _ = probe.read_tiff(path)
    return np.power(img, GAMMA) @ probe.PROPHOTO_Y.astype(np.float32)


def invert_series(base, layers, fractions, masked, floor=1e-6):
    """The coverage at each pixel: the fraction of the full effect that the masked export shows, inverted through the per-pixel curve
    the series gives. `base` and `masked` are linear luminance images, `layers` a list of the series' images at `fractions`
    (ascending, ending at 1), all the same size. Returns the coverage, 0 to 1, and the validity map."""
    fractions = np.asarray((0.0, *fractions), np.float32)
    logs = np.log2(np.maximum(np.stack([base, *layers]), floor))
    valid = (base > 2e-4) & (np.abs(logs[-1] - logs[0]) >= 0.15)
    sign = np.sign(logs[-1] - logs[0])
    sign[sign == 0] = 1
    z = np.maximum.accumulate(logs * sign, axis=0)
    del logs
    m = np.log2(np.maximum(masked, floor)) * sign
    i = np.clip((m[None] >= z).sum(0) - 1, 0, len(fractions) - 2)
    rows, cols = np.ogrid[:base.shape[0], :base.shape[1]]
    lo, hi = z[i, rows, cols], z[i + 1, rows, cols]
    span = np.maximum(hi - lo, 1e-6)
    alpha = fractions[i] + (np.clip(m, lo, hi) - lo) / span * (fractions[i + 1] - fractions[i])
    # a segment with no height: the response has gone flat (a clipped toe) and the masked value is at its end, so it has reached the upper knot
    alpha = np.where(hi - lo <= 1e-6, fractions[i + 1], alpha)
    return np.clip(alpha, 0, 1).astype(np.float32), valid


def downscale(a, weight):
    """Half size, weighted mean."""
    h, w = a.shape[0] // 2 * 2, a.shape[1] // 2 * 2
    a, weight = a[:h, :w], weight[:h, :w]
    sw = weight.reshape(h // 2, 2, w // 2, 2).sum((1, 3))
    sa = (a * weight).reshape(h // 2, 2, w // 2, 2).sum((1, 3))
    return sa / np.maximum(sw, 1e-9), (sw > 0).astype(np.float32)


def fill_invalid(alpha, valid):
    """Each invalid pixel takes the mean of the valid ones around it (a coarse-to-fine push-pull), valid pixels unchanged."""
    if valid.all():
        return alpha
    pyramid = [(alpha.astype(np.float32), valid.astype(np.float32))]
    while min(pyramid[-1][0].shape) > 2 and pyramid[-1][1].min() == 0:
        pyramid.append(downscale(*pyramid[-1]))
    filled = pyramid[-1][0]
    for a, w in reversed(pyramid[:-1]):
        # bilinear, so a filled hole has no blocks of the coarser level in it
        coarse = np.asarray(Image.fromarray(filled.astype(np.float32)).resize((a.shape[1], a.shape[0]), Image.BILINEAR), np.float32)
        filled = np.where(w > 0, a, coarse)
    return filled.astype(np.float32)


def tag(ev):
    return f"e{int(round(ev * 100)):+d}"


def state_folder(ev, fraction):
    return f"full-{tag(ev)}-{int(round(fraction * 1000)):04d}"


def masked_folder(ev):
    return f"masked-{tag(ev)}"


def recover_series(exports, name, base, ev, fractions):
    layers = [luminance(exports / state_folder(ev, f) / f"{name}.tif") for f in fractions]
    masked = luminance(exports / masked_folder(ev) / f"{name}.tif")
    return invert_series(base, layers, fractions, masked)


def blend(base, shadows, valid_shadows, highlights, valid_highlights):
    """The coverage from the two series: the shadow series below BLEND[0] of base luminance, the highlight series above BLEND[1], a ramp between;
    where only one is valid, that one. Returns the coverage and where it is valid."""
    w = np.clip((base - BLEND[0]) / (BLEND[1] - BLEND[0]), 0, 1).astype(np.float32)
    both = valid_shadows & valid_highlights
    mixed = np.where(both, shadows * (1 - w) + highlights * w, np.where(valid_shadows, shadows, highlights))
    return mixed.astype(np.float32), valid_shadows | valid_highlights


def recover_one(exports, name):
    base = luminance(exports / "base" / f"{name}.tif")
    (ev1, fractions1), (ev2, fractions2) = SERIES
    shadows, v1 = recover_series(exports, name, base, ev1, fractions1)
    highlights, v2 = recover_series(exports, name, base, ev2, fractions2)
    alpha, valid = blend(base, shadows, v1, highlights, v2)
    return fill_invalid(alpha, valid), float(valid.mean()), base


def recover(root, out):
    exports = Path(root) / "exports"
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    lines = []
    for tif in sorted((exports / masked_folder(SERIES[0][0])).glob("*.tif")):
        name = tif.stem
        alpha, share, _ = recover_one(exports, name)
        np.save(out / f"{name}.npy", alpha)
        lines.append(f"{name} {alpha.shape[1]}x{alpha.shape[0]} valid {share:.4f}")
        print(lines[-1], flush=True)
    (out / "recover.txt").write_text("\n".join(lines) + "\n")


def cosine_step(t):
    return 0.5 - 0.5 * np.cos(np.pi * np.clip(t, 0, 1))


def known_gradient(h, w, full, zero):
    """Lightroom's Linear gradient at each pixel: t in pixels perpendicular to the line, `1 - cosine((t - a) / (b - a))`."""
    fx, fy, zx, zy = full[0] * w, full[1] * h, zero[0] * w, zero[1] * h
    X, Y = np.meshgrid(np.arange(w, dtype=np.float32) + 0.5, np.arange(h, dtype=np.float32) + 0.5)
    dx, dy = zx - fx, zy - fy
    t = ((X - fx) * dx + (Y - fy) * dy) / (dx * dx + dy * dy)
    return 1 - cosine_step((t - LINEAR_A) / (LINEAR_B - LINEAR_A))


def validate(root):
    root = Path(root)
    exports = root / "exports"
    lines = []
    for label, (_, full, zero) in VALIDATION.items():
        alpha, share, base = recover_one(exports, label)
        truth = known_gradient(alpha.shape[0], alpha.shape[1], full, zero)
        d = alpha - truth
        lines.append(f"{label}: {alpha.shape[1]}x{alpha.shape[0]} valid {share:.4f} rms {float(np.sqrt((d ** 2).mean())):.5f} "
                     f"mean {float(d.mean()):+.5f} max|d| {float(np.abs(d).max()):.4f} p99.9 {float(np.quantile(np.abs(d[::16, ::16]), 0.999)):.4f}")
        for lo, hi in ((0, 0.005), (0.005, 0.03), (0.03, 0.18), (0.18, 0.6), (0.6, 2)):
            band = (base >= lo) & (base < hi)
            if band.any():
                lines.append(f"  base Y {lo:g}..{hi:g} ({100 * band.mean():.1f} %): rms {float(np.sqrt((d[band] ** 2).mean())):.5f} mean {float(d[band].mean()):+.5f}")
        np.save(root / f"{label}.recovered.npy", alpha[::4, ::4])
    print("\n".join(lines))
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    j = sub.add_parser("job")
    j.add_argument("--root", required=True)
    j.add_argument("--frames", required=True)
    j.add_argument("--raws", required=True)
    r = sub.add_parser("recover")
    r.add_argument("root")
    r.add_argument("out")
    v = sub.add_parser("validate")
    v.add_argument("root")
    args = parser.parse_args()
    if args.command == "job":
        write_job(args.root, args.frames, args.raws)
    elif args.command == "recover":
        recover(args.root, args.out)
    else:
        validate(args.root)


if __name__ == "__main__":
    main()
