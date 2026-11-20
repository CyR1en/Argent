"""Test inputs for the Lightroom slider probe (docs/research/lightroom-sliders.md).

    python -I make_charts.py chart OUT
        OUT/chart.tif: a 2400 x 1600 16-bit linear chart (ACEScg Linear ICC, white 1.0): rows 0-499 a
        smooth ramp from 12 stops under white to white, rows 500-999 the same ramp with a +/-0.25
        stop checkerboard of 8-pixel cells, rows 1000-1599 4 x 12 flat patches at shuffled
        log-spaced levels; and OUT/chart-layout.json. Lightroom renders a TIFF as an output-referred
        picture with no base curve, so it shows the controls on rendered pictures, not on raws.
    python -I make_charts.py locality OUT
        OUT/locality.dng: a 3000 x 2400 linear DNG (LinearRaw, linear sRGB primaries), which
        Lightroom renders as a raw: a smooth ramp from 12 stops under the sensor's white to white,
        then three bands of squares 8 to 512 pixels wide, bright on a dark surround, bright on a mid
        surround, and dark on a bright surround; and OUT/locality-layout.json.
    python -I make_charts.py adaptation OUT
        OUT/adapt-<content>.dng: six 3000 x 2000 linear DNGs with the same smooth ramp in rows 0-399
        over different content (all dark, mid, bright or white; half dark and half bright; a random
        texture), to tell image adaptation from local behaviour: a local operator leaves the ramp's
        top rows alone whatever lies below them, an adaptive one does not.
    python -I make_charts.py raws OUT RAW
        OUT/raw_NN_<variant>.<ext> clones of RAW with XMP sidecars, one per probe variant. Lightroom
        reads sidecars on import, not when re-reading metadata of photos already in its catalog; the
        plug-in's jobs (jobs.py) set the values themselves and are what the probe used.
    python -I make_charts.py masks OUT [SCALE]
        The charts of the mask session (jobs.py masks), linear DNGs
        like the others, since Lightroom ignores settings embedded in TIFFs: OUT/mask-ramp.dng (2000 x
        1200, every row the same smooth ramp from 12 stops under white to white, so a mask that
        varies down the rows meets every tone) and OUT/mask-flat.dng (1600 x 1000, one flat field 2.5
        stops under white, about mid-gray, for the shape of a mask's edge) and OUT/mask-flat-half.dng (the same
        at 800 x 500), each with its layout JSON. SCALE (default 1) shrinks them, for tests.
    python -I make_charts.py presence OUT [LAYOUTS] [--prefix q-]
        The Presence probe's charts (presence_charts.py), OUT/p-*.dng and OUT/p-colour-grid.tif, for Texture
        and Clarity (gratings at four mean levels, steps, colour and noise, half-size twins), Dehaze (a flat
        field, flats and a ramp, synthetic haze with three airlights, the locality chart and its twin), Vibrance
        and Saturation (the colour grid) and their combinations (p-combo). Each chart's layout, every region
        with its pixel box and ground truth, goes to OUT/<chart>-layout.json and, if given, LAYOUTS/<chart>.json.
        Only the charts whose name starts with the prefix (default p-, round 1); q- writes round 2's (the tone
        charts for Clarity's frame adaptation and the edge chart).
"""
import json
import struct
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import probe  # noqa: E402


def chart():
    W, H, low = 2400, 1600, -12.0
    stops = low * (1 - (np.arange(W) + 0.5) / W)
    img = np.empty((H, W))
    img[0:500] = np.exp2(stops)[None, :]
    yy, xx = np.mgrid[0:500, 0:W]
    check = np.where(((yy // 8) + (xx // 8)) % 2 == 0, 0.25, -0.25)
    img[500:1000] = np.exp2(np.minimum(stops[None, :] + check, 0))
    levels = np.linspace(low, 0, 48)
    order = np.random.default_rng(7).permutation(48)
    patches = []
    pw, ph = W // 12, 600 // 4
    for i, k in enumerate(order):
        r, c = divmod(i, 12)
        img[1000 + r * ph:1000 + (r + 1) * ph, c * pw:(c + 1) * pw] = np.exp2(levels[k])
        patches.append({"row": r, "col": c, "stops": float(levels[k]),
                        "box": [c * pw, 1000 + r * ph, (c + 1) * pw, 1000 + (r + 1) * ph]})
    rgb = np.repeat(np.clip(img, 0, 1)[:, :, None], 3, axis=2)
    layout = {"width": W, "height": H, "ramp_rows": [0, 500], "texture_rows": [500, 1000], "texture_cell": 8,
              "texture_stops": 0.25, "ramp_stops": [low, 0.0], "encoding": "linear, ACEScg primaries, white 1.0, 16-bit",
              "patches": patches}
    return np.round(rgb * 65535).astype("<u2"), layout


# The locality chart's levels in stops under the sensor's white, and its square sizes.
SIZES = [8, 16, 32, 64, 128, 256, 512]
ROWS = [("bright on dark", -7.0, -2.0), ("bright on mid", -4.5, -2.0), ("dark on bright", -2.0, -7.0)]


def locality(scale=1.0):
    W, H = round(3000 * scale), round(2400 * scale)
    sizes = SIZES if scale == 1.0 else [max(2, round(size * scale)) for size in SIZES]
    row_h = H // (len(ROWS) + 1)
    img = np.empty((H, W))
    # Band 0: a smooth ramp from 12 stops under white to white, the flat response.
    img[:row_h] = np.exp2(-12 * (1 - (np.arange(W) + 0.5) / W))[None, :]
    squares = []
    for r, (name, surround, level) in enumerate(ROWS):
        y0 = (r + 1) * row_h
        img[y0:y0 + row_h] = 2.0 ** surround
        gap = (W - sum(sizes)) // (len(sizes) + 1)
        x = gap
        for size in sizes:
            top = y0 + (row_h - size) // 2
            img[top:top + size, x:x + size] = 2.0 ** level
            squares.append({"row": name, "surroundStops": surround, "stops": level, "size": size,
                            "box": [x, top, x + size, top + size]})
            x += size + gap
    layout = {"width": W, "height": H, "encoding": "LinearRaw DNG, linear sRGB primaries, white level 65535",
              "ramp": {"band": [0, row_h], "stops": [-12.0, 0.0]},
              "rows": [{"name": n, "surroundStops": s, "stops": l, "band": [(i + 1) * row_h, (i + 2) * row_h]}
                       for i, (n, s, l) in enumerate(ROWS)], "squares": squares}
    return np.round(np.repeat(img[:, :, None], 3, axis=2) * 65535).astype("<u2"), layout


# The adaptation charts' content below the ramp, by name: what the rest of the frame holds.
CONTENT = {
    "dark": "all 7 stops under white",
    "mid": "all 3.5 stops under white",
    "bright": "all 1 stop under white",
    "white": "all at white, as clipped sky",
    "split": "left half 7 stops under white, right half 1 stop under",
    "texture": "16-pixel cells at levels drawn evenly from 9 stops under white to white",
}


def adaptation(content, scale=1.0):
    """A 3000 x 2000 frame: a smooth ramp from 12 stops under white to white in rows 0-399, the
    same in every chart, over `content` in rows 400-1999. Lightroom's change on the ramp's top rows,
    far from the content, shows whether its controls follow the rest of the frame."""
    W, H, band = round(3000 * scale), round(2000 * scale), round(400 * scale)
    img = np.empty((H, W))
    img[:band] = np.exp2(-12 * (1 - (np.arange(W) + 0.5) / W))[None, :]
    rest = img[band:]
    if content == "dark":
        rest[:] = 2.0 ** -7
    elif content == "mid":
        rest[:] = 2.0 ** -3.5
    elif content == "bright":
        rest[:] = 2.0 ** -1
    elif content == "white":
        rest[:] = 1.0
    elif content == "split":
        rest[:, :W // 2], rest[:, W // 2:] = 2.0 ** -7, 2.0 ** -1
    else:
        cell = max(2, round(16 * scale))
        cells = np.random.default_rng(29).uniform(-9, 0, ((H - band) // cell, -(-W // cell)))
        rest[:] = np.exp2(np.kron(cells, np.ones((cell, cell))))[:H - band, :W]
    layout = {"width": W, "height": H, "ramp": {"band": [0, band], "measure": [round(30 * scale), round(200 * scale)], "stops": [-12.0, 0.0]},
              "content": content, "description": CONTENT[content]}
    return np.round(np.repeat(img[:, :, None], 3, axis=2) * 65535).astype("<u2"), layout


# The mask session's charts. The ramp's every row is the same, so a mask that changes down the rows
# meets every tone at every coverage; the flat chart is one tone, for the shape of a mask's edge.
MASK_RAMP = (2000, 1200)
MASK_FLAT = (1600, 1000)
MASK_FLAT_STOPS = -2.5


def mask_ramp(scale=1.0):
    W, H = round(MASK_RAMP[0] * scale), round(MASK_RAMP[1] * scale)
    row = np.exp2(-12 * (1 - (np.arange(W) + 0.5) / W))
    layout = {"width": W, "height": H, "ramp": {"stops": [-12.0, 0.0], "rows": [0, H]},
              "description": "every row the same ramp, 12 stops under white to white"}
    return np.round(np.repeat(np.tile(row, (H, 1))[:, :, None], 3, axis=2) * 65535).astype("<u2"), layout


def mask_flat(scale=1.0, stops=MASK_FLAT_STOPS):
    W, H = round(MASK_FLAT[0] * scale), round(MASK_FLAT[1] * scale)
    layout = {"width": W, "height": H, "stops": stops, "description": f"one flat field {-stops:g} stops under white"}
    return np.round(np.full((H, W, 3), 2.0 ** stops) * 65535).astype("<u2"), layout


def tiff(entries, pixels):
    """A little-endian TIFF with one strip; `entries` are (tag, type, count, packed value)."""
    h, w, _ = pixels.shape
    data = pixels.tobytes()
    entries = sorted(entries + [(273, 4, 1, struct.pack("<I", 0)), (278, 4, 1, struct.pack("<I", h)),
                                (279, 4, 1, struct.pack("<I", len(data)))], key=lambda e: e[0])
    offset = 8 + 2 + len(entries) * 12 + 4
    extra, out = bytearray(), []
    for tag, kind, count, value in entries:
        if len(value) <= 4:
            out.append((tag, kind, count, value.ljust(4, b"\0")))
        else:
            if len(extra) % 2:
                extra += b"\0"
            out.append((tag, kind, count, struct.pack("<I", offset + len(extra))))
            extra += value
    if len(extra) % 2:
        extra += b"\0"
    strip = offset + len(extra)
    out = [(t, k, c, struct.pack("<I", strip) if t == 273 else v) for t, k, c, v in out]
    body = b"II*\0" + struct.pack("<I", 8) + struct.pack("<H", len(out))
    body += b"".join(struct.pack("<HHI", t, k, c) + v for t, k, c, v in out) + struct.pack("<I", 0)
    return body + bytes(extra) + data


def short(tag, *v):
    return (tag, 3, len(v), struct.pack(f"<{len(v)}H", *v))


def long_(tag, *v):
    return (tag, 4, len(v), struct.pack(f"<{len(v)}I", *v))


def ascii_(tag, text):
    b = text.encode() + b"\0"
    return (tag, 2, len(b), b)


def srational(tag, *v):
    return (tag, 10, len(v), b"".join(struct.pack("<ii", int(round(x * 10000)), 10000) for x in v))


def rational(tag, *v):
    return (tag, 5, len(v), b"".join(struct.pack("<II", int(round(x * 10000)), 10000) for x in v))


def write_chart_tiff(path, pixels, icc="/System/Library/ColorSync/Profiles/ACESCG Linear.icc"):
    icc = Path(icc).read_bytes()
    h, w, _ = pixels.shape
    entries = [long_(256, w), long_(257, h), short(258, 16, 16, 16), short(259, 1), short(262, 2), short(277, 3),
               short(284, 1), (34675, 7, len(icc), icc)]
    Path(path).write_bytes(tiff(entries, pixels))


# XYZ (D65) to linear sRGB: the chart's camera is linear sRGB, so a gray is neutral as shot.
XYZ_TO_SRGB = [3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434, -0.2040259, 1.0572252]


def write_dng(path, pixels, matrix=XYZ_TO_SRGB):
    """`matrix` is ColorMatrix1, XYZ (D65) to the chart's linear RGB, row by row."""
    h, w, _ = pixels.shape
    entries = [long_(254, 0), long_(256, w), long_(257, h), short(258, 16, 16, 16), short(259, 1), short(262, 34892),
               ascii_(271, "Argent"), ascii_(272, "Probe Chart"), short(274, 1), short(277, 3), short(284, 1),
               ascii_(305, "scripts/lightroom-probe/make_charts.py"),
               (50706, 1, 4, bytes([1, 4, 0, 0])), (50707, 1, 4, bytes([1, 1, 0, 0])),
               ascii_(50708, "Argent Probe Chart"), short(50717, 65535, 65535, 65535),
               srational(50721, *matrix), rational(50728, 1, 1, 1), srational(50730, 0), short(50778, 21)]
    Path(path).write_bytes(tiff(entries, pixels))


NEUTRAL = {
    "Exposure2012": "+0.00", "Contrast2012": "0", "Highlights2012": "0", "Shadows2012": "0",
    "Whites2012": "0", "Blacks2012": "0", "Texture": "0", "Clarity2012": "0", "Dehaze": "0",
    "Vibrance": "0", "Saturation": "0", "Sharpness": "0", "LuminanceSmoothing": "0",
    "ColorNoiseReduction": "0", "LensProfileEnable": "0", "AutoLateralCA": "0",
    "PostCropVignetteAmount": "0", "GrainAmount": "0", "ToneCurveName2012": "Linear",
    "WhiteBalance": "As Shot",
}


def xmp(settings):
    s = dict(NEUTRAL, **settings)
    attrs = "\n".join(f'   crs:{k}="{v}"' for k, v in s.items())
    curve = "<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>"
    return f'''<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
   xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
   crs:Version="17.0"
   crs:ProcessVersion="15.4"
   crs:HasSettings="True"
{attrs}>
   {curve}
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>'''.encode("utf-8")


def raws(out, raw):
    out.mkdir(parents=True, exist_ok=True)
    keys = {"exposure": "Exposure2012", "contrast": "Contrast2012", "highlights": "Highlights2012",
            "shadows": "Shadows2012", "whites": "Whites2012", "blacks": "Blacks2012"}
    for i, (control, value) in enumerate(probe.variants()):
        stem = "raw_00_base" if control is None else f"raw_{i:02d}_{probe.variant_name(control, value)}"
        target = out / f"{stem}{raw.suffix}"
        if not target.exists():
            subprocess.run(["cp", "-c", str(raw), str(target)], check=True)
        settings = {} if control is None else {keys[control]: f"{value:+.2f}" if control == "exposure" else f"{value:+d}"}
        (out / f"{stem}.xmp").write_bytes(xmp(settings))


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("chart", "locality", "adaptation", "raws", "masks", "presence"):
        raise SystemExit(__doc__)
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    if sys.argv[1] == "chart":
        pixels, layout = chart()
        write_chart_tiff(out / "chart.tif", pixels)
        (out / "chart-layout.json").write_text(json.dumps(layout, indent=1))
    elif sys.argv[1] == "locality":
        pixels, layout = locality()
        write_dng(out / "locality.dng", pixels)
        (out / "locality-layout.json").write_text(json.dumps(layout, indent=1))
    elif sys.argv[1] == "adaptation":
        for content in CONTENT:
            pixels, layout = adaptation(content)
            write_dng(out / f"adapt-{content}.dng", pixels)
            (out / f"adapt-{content}-layout.json").write_text(json.dumps(layout, indent=1))
    elif sys.argv[1] == "masks":
        scale = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
        for name, make, relative in (("mask-ramp", mask_ramp, 1.0), ("mask-flat", mask_flat, 1.0), ("mask-flat-half", mask_flat, 0.5)):
            pixels, layout = make(scale * relative)
            write_dng(out / f"{name}.dng", pixels)
            (out / f"{name}-layout.json").write_text(json.dumps(layout, indent=1))
    elif sys.argv[1] == "presence":
        import presence_charts
        rest = sys.argv[3:]
        prefix = rest.pop(rest.index("--prefix") + 1) if "--prefix" in rest else "p-"
        rest = [a for a in rest if a != "--prefix"]
        layouts = Path(rest[0]) if rest else None
        for name in (n for n in presence_charts.CHARTS if n.startswith(prefix)):
            layout = json.dumps(presence_charts.write(name, out), indent=1)
            (out / f"{name}-layout.json").write_text(layout)
            if layouts:
                layouts.mkdir(parents=True, exist_ok=True)
                (layouts / f"{name}.json").write_text(layout)
            print(f"  {name}")
    else:
        raws(out, Path(sys.argv[3]))
    print(f"wrote {sys.argv[1]} into {out}")


if __name__ == "__main__":
    main()
