"""Synthetic exports for the mask session: a made-up Lightroom with laws we choose, to try the analysis without Lightroom.

The oracle renders every item of the plan (masks_plan.py) from the same JSON tables the plug-in would write, under a `World`
of explicit laws: how a partial coverage scales an adjustment, the edge profile, how components combine, how two masks
combine, what Amount scales, which base Highlights and Shadows read, which of a mask and the panel goes first, the
range of local Exposure. Its output is 16-bit ProPhoto-gamma TIFFs in the format of Lightroom's exports, so
analyze_masks.py reads them like the real ones. test_masks.py renders a world, runs the analysis and checks it names the
laws; then it flips a law and checks that the analysis notices.

The tone model is invented (a logistic transfer, bell-shaped gains), and so are the controls' shapes; only the *composition*
laws are what is being recovered. Nothing here is a claim about Lightroom.

    python -I synth_masks.py OUTROOT [--world r5|flipped|mixed] [--scale 0.25] [--only m00-smoke,...]
"""
import argparse
import json
import struct
import sys
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_charts  # noqa: E402
import mask_models as mm  # noqa: E402
import masks_plan  # noqa: E402
import probe  # noqa: E402

GAMMA = 461 / 256

# The made-up transfer: output L* of a scene level (stops under white): mid-gray at -2.5 stops, a toe and a shoulder.
MID, SPREAD = -2.5, 1.6


def transfer(level):
    return 100.0 / (1.0 + np.exp(-(level - MID) / SPREAD))


def bell(x, centre, width):
    return np.exp(-(((x - centre) / width) ** 2))


# The made-up controls, gains in stops at a level (Highlights and Shadows read the local base's level). Nonlinear in the
# value where Lightroom's are (Whites above all).
def gain_E(level, v):
    return v + 0 * level


def gain_C(level, v):
    return (v / 100.0) * 0.8 * np.tanh((level - MID) / 2.0)


def gain_H(level, v):
    return (v / 100.0) * 1.3 * bell(level, -0.5, 2.2)


def gain_S(level, v):
    return (v / 100.0) * 1.3 * bell(level, -5.0, 2.6)


def gain_W(level, v):
    v = np.asarray(v, float)
    m = np.abs(v) / 100.0
    return np.sign(v) * np.where(v >= 0, m ** 1.8, m) * 1.6 * bell(level, -1.8, 2.4)


def gain_B(level, v):
    v = np.asarray(v, float)
    return np.sign(v) * (np.abs(v) / 100.0) ** 1.4 * 1.4 * bell(level, -6.0, 3.0)


GAINS = {"E": gain_E, "C": gain_C, "H": gain_H, "S": gain_S, "W": gain_W, "B": gain_B}


@dataclass(frozen=True)
class World:
    name: str = "r5"
    coverage: str = "gain"          # how a coverage scales an adjustment: gain (R5) | slider | blendL | blendY
    profile: str = "smoothstep"     # linear gradient: smoothstep | linear | smootherstep | cosine
    radial: str = "inward"          # feather inside the outline (R8) | straddle: centred on the outline
    algebra: str = "prob"           # prob (R8) | minmax | luk
    overlap: str = "r5"             # r5 | sum | seq (every gain at the level so far) | perlayer
    amount: str = "slider"          # Amount scales: slider (R5) | gain
    base: str = "shared"            # the base Highlights/Shadows read: shared (R5) | masked
    order: str = "panel-first"      # panel-first (R5) | masks-first: which of the panel and the masks acts first
    exposure_scale: float = 4.0     # panel EV = stored * exposure_scale
    exposure_clip: float = 4.0
    amount_max: float = 1.0
    slider_clip: float = 100.0
    lum_full: bool = True           # whether LumRange "0 0 1 1" covers the frame
    edge_px: float = 1.5            # the width of a feather-0 edge, in pixels
    adapt: str = "none"            # Highlights/Shadows strength follows the mean level of: none | frame | region (the mask's own)
    gradient_space: str = "pixel"    # linear gradients measured in pixels (perpendicular on the picture) or in normalized axes


WORLDS = {
    "r5": World("r5", adapt="frame"),
    "flipped": World("flipped", adapt="region", coverage="slider", profile="linear", radial="straddle", algebra="minmax", overlap="sum",
                     amount="slider", base="masked", order="masks-first", exposure_scale=3.0, exposure_clip=3.0, amount_max=2.0,
                     gradient_space="normalized"),
    "mixed": World("mixed", coverage="gain", profile="smootherstep", radial="inward", algebra="luk", overlap="perlayer",
                   amount="gain", base="shared", order="masks-first", exposure_clip=4.0, amount_max=1.0),
    "blend": World("blend", coverage="blendY"),
}


def sizes(chart, scale):
    nominal = {"R": make_charts.MASK_RAMP, "F": make_charts.MASK_FLAT, "F2": (800, 500), "L": (3000, 2400),
               "AD": (3000, 2000), "AB": (3000, 2000), "P": (7008, 4672), "P2": (7008, 4672), "P3": (7008, 4672)}[chart]
    s = scale[chart] if isinstance(scale, dict) else scale
    return round(nominal[0] * s), round(nominal[1] * s)


def levels(chart, scale):
    """Scene level in stops under white of every pixel of a chart, as make_charts writes it (a made-up picture for P)."""
    w, h = sizes(chart, scale)
    s = scale[chart] if isinstance(scale, dict) else scale
    if chart == "R":
        return np.tile(-12 + 12 * (np.arange(w) + 0.5) / w, (h, 1))
    if chart in ("F", "F2"):
        return np.full((h, w), make_charts.MASK_FLAT_STOPS)
    if chart == "L":
        px, _ = make_charts.locality(s)
    elif chart in ("AD", "AB"):
        px, _ = make_charts.adaptation("dark" if chart == "AD" else "bright", s)
    else:
        rng = np.random.default_rng(5)
        yy, xx = np.mgrid[0:h, 0:w]
        field = -3.5 + 2.2 * np.sin(xx / w * 5.1) * np.cos(yy / h * 3.7) - 3.5 * np.exp(-(((yy / h) - 0.78) ** 2) / 0.02)
        field += 0.15 * rng.standard_normal((h, w))
        return np.clip(field, -11, 1.5)
    lin = px[:, :, 0].astype(float) / 65535.0
    return np.log2(np.maximum(lin, 2.0 ** -16))


def box_blur(a, r):
    """Mean over a (2r+1)^2 window with clamped edges."""
    return probe.box(a, max(1, int(r)))


def masked_base(x, c, r):
    """Normalized convolution: the level averaged over the covered pixels only."""
    num = box_blur(x * c, r)
    den = box_blur(c, r)
    return np.where(den > 1e-3, num / np.maximum(den, 1e-3), x)


# MARK: Coverage of a mask

def component_field(comp, h, w, world):
    what = comp["What"]
    if what == "Mask/Gradient":
        t = probe_t(h, w, (comp["FullX"], comp["FullY"]), (comp["ZeroX"], comp["ZeroY"]), world.gradient_space == "pixel")
        v = 1 - PROFILE[world.profile](t)
    elif what == "Mask/CircularGradient":
        n, (rx, ry) = mm.radial_n(h, w, comp["Left"], comp["Top"], comp["Right"], comp["Bottom"], comp["Angle"])
        f = comp["Feather"] / 100.0
        S = PROFILE[world.profile]
        if f <= 1e-6:
            v = np.clip(0.5 - (n - 1) * min(rx, ry) / world.edge_px, 0, 1)
        elif world.radial == "inward":
            v = 1 - S((n - (1 - f)) / f)
        else:
            v = 1 - S((n - (1 - f / 2)) / f)
    elif what == "Mask/RangeMask":
        v = np.ones((h, w)) if world.lum_full else np.zeros((h, w))
    else:
        raise ValueError(what)
    return 1 - v if comp["MaskInverted"] else v


def probe_t(h, w, full, zero, pixel_space=True):
    return mm.gradient_t(h, w, full, zero, pixel_space)


def _smoothstep(t): t = np.clip(t, 0, 1); return t * t * (3 - 2 * t)
def _smootherstep(t): t = np.clip(t, 0, 1); return t ** 3 * (t * (6 * t - 15) + 10)
def _linear(t): return np.clip(t, 0, 1)
def _cosine(t): return 0.5 - 0.5 * np.cos(np.pi * np.clip(t, 0, 1))


PROFILE = {"smoothstep": _smoothstep, "smootherstep": _smootherstep, "linear": _linear, "cosine": _cosine}

ALGEBRA = {
    "prob": {"add": lambda c, v: 1 - (1 - c) * (1 - v), "sub": lambda c, v: c * (1 - v)},
    "minmax": {"add": lambda c, v: np.maximum(c, v), "sub": lambda c, v: np.minimum(c, 1 - v)},
    "luk": {"add": lambda c, v: np.minimum(1, c + v), "sub": lambda c, v: np.maximum(0, c - v)},
}


def correction_coverage(corr, h, w, world):
    c = np.zeros((h, w))
    for comp in corr["CorrectionMasks"]:
        v = component_field(comp, h, w, world)
        op = "sub" if comp["MaskBlendMode"] == 1 else "add"
        c = ALGEBRA[world.algebra][op](c, v)
    return c


# MARK: One item

def panel_of(glob):
    """Global develop settings as {control: value}."""
    out = {}
    for ctrl, (key, _, _) in masks_plan.CONTROLS.items():
        if key in glob:
            out[ctrl] = float(glob[key])
    return out


def layers_of(masks, world):
    layers = []
    for corr in masks or []:
        if not corr.get("CorrectionActive", True):
            continue
        amount = min(max(float(corr.get("CorrectionAmount", 1.0)), 0.0), world.amount_max)
        values = {}
        for ctrl, (_, local, divisor) in masks_plan.CONTROLS.items():
            if local in corr:
                v = float(corr[local]) * (world.exposure_scale if ctrl == "E" else divisor)
                clip = world.exposure_clip if ctrl == "E" else world.slider_clip
                values[ctrl] = float(np.clip(v, -clip, clip))
        layers.append({"corr": corr, "values": values, "amount": amount})
    return layers


def adapt_factor(x, c, mode):
    if mode == "none":
        return 1.0
    mean = float(np.mean(x)) if (mode == "frame" or c is None) else float(np.sum(x * c) / max(np.sum(c), 1e-6))
    return 1.0 + 0.12 * (mean + 4.0)


def render_item(item, world, scale):
    x = levels(item.chart, scale)
    h, w = x.shape
    panel = panel_of(item.glob)
    panel = {k: float(np.clip(v, -5 if k == "E" else -world.slider_clip, 5 if k == "E" else world.slider_clip)) for k, v in panel.items()}
    layers = layers_of(item.masks, world)
    for layer in layers:
        layer["c"] = correction_coverage(layer["corr"], h, w, world)
        layer["k"], layer["mult"] = layer["c"], 1.0
        if world.amount == "gain" and world.overlap != "sum" and world.coverage not in ("blendL", "blendY"):
            layer["mult"] = layer["amount"]            # Amount multiplies the layer's gains in stops, whatever the coverage does
        elif world.coverage in ("blendL", "blendY"):
            layer["k"] = layer["c"] * layer["amount"]
        else:
            layer["values"] = {k: v * layer["amount"] for k, v in layer["values"].items()}   # Amount scales the sliders
    f_frame = adapt_factor(x, None, world.adapt)
    for layer in layers:
        layer["f"] = adapt_factor(x, layer["c"], world.adapt)
    r = max(1, round(0.015 * w))
    xb = box_blur(x, r)                       # the shared base; the ramp and flat charts are their own base
    if item.chart in ("R", "F", "F2"):
        xb = x

    def own_base(layer):
        return masked_base(x, layer["c"], r) if (world.base == "masked" and item.chart not in ("R", "F", "F2")) else xb

    if world.coverage in ("blendL", "blendY"):
        return blend_world(x, xb, panel, layers, world)

    e_panel = panel.get("E", 0.0)
    if world.overlap == "sum":
        # one evaluation of the sliders summed per pixel (each weighted by its coverage), Exposure added in stops
        sliders = {c: panel.get(c, 0.0) for c in "CHSWB"}
        e = e_panel
        for layer in layers:
            for c in "CHSWB":
                sliders[c] = sliders[c] + layer["k"] * layer["values"].get(c, 0.0)
            e = e + layer["k"] * layer["values"].get("E", 0.0)
        u = x + e
        t = np.zeros_like(u)
        for ctrl in ("H", "S"):
            num = abs(panel.get(ctrl, 0.0)) * f_frame
            den = abs(panel.get(ctrl, 0.0)) + 0 * u
            for layer in layers:
                wgt = layer["k"] * abs(layer["values"].get(ctrl, 0.0))
                num, den = num + wgt * layer["f"], den + wgt
            factor = np.where(den > 0, num / np.maximum(den, 1e-9), 1.0)
            if np.any(np.asarray(sliders[ctrl]) != 0):
                t = t + factor * GAINS[ctrl](xb + e + t, sliders[ctrl])
        t = t + global_part(sliders, 1.0, u + t, world)
        return transfer(u + t)

    if world.overlap == "seq":
        # strictly one after another: each layer's exposure, then its locals and globals, every gain at the level so far
        level = x.copy()
        for entry in (([None] + layers) if world.order == "panel-first" else (layers + [None])):
            vals, k, m, f = (panel, 1.0, 1.0, f_frame) if entry is None else (entry["values"], entry["k"], entry["mult"], entry["f"])
            level = level + k * m * vals.get("E", 0.0)
            level = level + local_part(vals, k, xb + (level - x), world, f, m)
            level = level + global_part(vals, k, level, world, m)
        return transfer(level)

    # all exposure first
    e = e_panel + sum(layer["k"] * layer["mult"] * layer["values"].get("E", 0.0) for layer in layers)
    u, ub = x + e, xb + e
    t = np.zeros_like(u)
    sequence = ([None] + layers) if world.order == "panel-first" else (layers + [None])
    if world.overlap == "perlayer":
        # each layer in turn, its locals at the base and then its globals, the panel first or last
        for entry in sequence:
            vals, k, base = (panel, 1.0, ub) if entry is None else (entry["values"], entry["k"], own_base(entry) + e)
            m = 1.0 if entry is None else entry["mult"]
            tl = local_part(vals, k, base, world, f_frame if entry is None else entry["f"], m)
            t = t + tl + global_part(vals, k, u + t + tl, world, m)
        return transfer(u + t)

    # r5: every local gain at the base, summed; then global gains in list order, the panel first or last
    t = t + local_part(panel, 1.0, ub, world, f_frame)
    for layer in layers:
        t = t + local_part(layer["values"], layer["k"], own_base(layer) + e, world, layer["f"], layer["mult"])
    for entry in sequence:
        vals, k, m = (panel, 1.0, 1.0) if entry is None else (entry["values"], entry["k"], entry["mult"])
        t = t + global_part(vals, k, u + t, world, m)
    return transfer(u + t)


def local_part(values, scale, base, world, factor=1.0, mult=1.0):
    t = np.zeros_like(base)
    for ctrl in ("H", "S"):
        if np.any(np.asarray(values.get(ctrl, 0)) != 0):
            v = values[ctrl]
            t = t + mult * factor * (scale * GAINS[ctrl](base + t, v) if world.coverage != "slider" else GAINS[ctrl](base + t, scale * v))
    return t


def global_part(values, scale, level, world, mult=1.0):
    t = np.zeros_like(level)
    for ctrl in ("W", "B", "C"):
        if np.any(np.asarray(values.get(ctrl, 0)) != 0):
            v = values[ctrl]
            t = t + mult * (scale * GAINS[ctrl](level + t, v) if world.coverage != "slider" else GAINS[ctrl](level + t, scale * v))
    return t


def blend_world(x, xb, panel, layers, world):
    """Blending laws: the layer is applied at full strength and mixed with the result without it by the coverage, in L* or in luminance."""
    e = panel.get("E", 0.0)
    u = x + e
    t = local_part(panel, 1.0, xb + e, world, adapt_factor(x, None, world.adapt)) + global_part(panel, 1.0, u, world)
    base_L = transfer(u + t)
    out = base_L
    for layer in layers:
        full_scale = 1.0
        lv = layer["values"]
        ue = u + lv.get("E", 0.0)
        tt = local_part(lv, full_scale, xb + e + lv.get("E", 0.0), replace(world, coverage="gain"))
        tt = tt + global_part(lv, full_scale, ue + tt, replace(world, coverage="gain"))
        # the layer on top of the panel's own change
        full = transfer(ue + t + tt)
        c = layer["k"]
        if world.coverage == "blendL":
            out = (1 - c) * out + c * full
        else:
            out = probe.lstar((1 - c) * probe.luminance(out) + c * probe.luminance(full))
    return out


# MARK: Writing exports

def icc_gamma_profile(gamma=GAMMA):
    """A bare ICC profile: a header and one rTRC tag holding a pure gamma, which is all probe.icc_gamma reads."""
    body = b"curv" + b"\0\0\0\0" + struct.pack(">I", 1) + struct.pack(">H", round(gamma * 256)) + b"\0\0"
    tag_table = struct.pack(">I", 1) + b"rTRC" + struct.pack(">II", 144, len(body))
    header = bytearray(128)
    header[:4] = struct.pack(">I", 144 + len(body))
    header[12:16], header[16:20] = b"mntr", b"RGB "
    return bytes(header) + tag_table + body


def write_export(path, lstar):
    """A 16-bit ProPhoto-gamma TIFF of a gray image whose CIE L* is `lstar`."""
    y = np.clip(probe.luminance(np.clip(lstar, 0, 100)), 0, 1)
    enc = np.round(np.power(y, 1 / GAMMA) * 65535).astype("<u2")
    pixels = np.repeat(enc[:, :, None], 3, axis=2)
    h, w, _ = pixels.shape
    icc = icc_gamma_profile()
    entries = [make_charts.long_(256, w), make_charts.long_(257, h), make_charts.short(258, 16, 16, 16), make_charts.short(259, 1),
               make_charts.short(262, 2), make_charts.short(277, 3), make_charts.short(284, 1), (34675, 7, len(icc), icc)]
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(make_charts.tiff(entries, pixels))


def render_plan(plan, world, root, scale, only=None, items=None):
    """Writes exports-<job>/<job>_<id>.tif for the plan's items (or the `items` ids) under `world`; a .done per job."""
    root = Path(root)
    n = 0
    for job in plan.jobs:
        if only and job.name not in only:
            continue
        out = root / f"exports-{job.name}"
        out.mkdir(parents=True, exist_ok=True)
        for item in job.items:
            if items is not None and item.id not in items:
                continue
            write_export(masks_plan.export_path(item, root), render_item(item, world, scale))
            n += 1
        (root / "jobs").mkdir(exist_ok=True)
        (root / "jobs" / f"{job.name}.done").write_text(f"INFO\tplugin\tsynthetic\nDONE\t{len(job.items)}\n")
    (root / "masks-plan.json").write_text(json.dumps(plan.to_json(), indent=1, sort_keys=True))
    return n


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root")
    parser.add_argument("--world", default="r5", choices=sorted(WORLDS))
    parser.add_argument("--scale", type=float, default=0.25)
    parser.add_argument("--only")
    args = parser.parse_args()
    plan = masks_plan.build()
    scale = {c: args.scale for c in masks_plan.CHARTS}
    scale["P"] = min(args.scale, 0.1)
    n = render_plan(plan, WORLDS[args.world], args.root, scale, only=args.only.split(",") if args.only else None)
    print(f"{n} synthetic exports of world '{args.world}' under {args.root}")


if __name__ == "__main__":
    main()
