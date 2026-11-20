"""The Presence probe's charts, for Texture, Clarity, Dehaze, Vibrance and Saturation (`make_charts.py presence`).

Every chart is a linear DNG, which Lightroom renders as a raw (Embedded profile, no look). The colour grid is
also a 16-bit TIFF, which Lightroom renders as a finished picture. One is a photograph, not a synthetic chart:
r-sky-matrix is the spike's decode of a raw (DECODED), so it rebuilds only where the main checkout's spike runs. A
value is linear light with white 1.0 (65535) and middle grey 0.18. "Stops" are log2 of a value over middle grey
unless a field says otherwise.

A chart's layout names every region with its pixel box [x0, y0, x1, y1] (x1 and y1 exclusive, the export's own
pixels, since Lightroom exports a chart at its size) and the region's ground truth. CHARTS maps each chart's name
to the function that builds it, so a fit agent can rebuild the exact input:

    import presence_charts; chart = presence_charts.CHARTS["p-grating-0"]()   # chart.img, chart.layout()
"""
import numpy as np

import make_charts

MID = 0.18
REC2020_TO_XYZ = np.array([[0.636958, 0.144617, 0.168881],
                           [0.262700, 0.677998, 0.059302],
                           [0.000000, 0.028073, 1.060985]])
XYZ_TO_REC2020 = np.linalg.inv(REC2020_TO_XYZ)
REC2020_Y = REC2020_TO_XYZ[1]
D65 = np.array([0.95047, 1.0, 1.08883])
ITU2020_ICC = "/System/Library/ColorSync/Profiles/ITU-2020.icc"
ENCODING = {"Rec. 2020": "LinearRaw DNG, 16-bit, linear Rec. 2020 primaries (ColorMatrix1 XYZ D65 to Rec. 2020), "
                         "As Shot neutral 1, 1, 1, white 1.0 = 65535",
            "sRGB": "LinearRaw DNG, 16-bit, linear sRGB primaries, As Shot neutral 1, 1, 1, white 1.0 = 65535"}


def stops(s):
    return MID * 2.0 ** np.asarray(s, dtype=np.float64)


def sinusoid(x, x0, period):
    """sin(2 pi (x - x0 + 0.5) / period) at column x: zero at the cell's left border, and at period 2 it
    alternates +1 and -1 from pixel to pixel instead of sampling the zeros."""
    return np.sin(2 * np.pi * (np.asarray(x, dtype=np.float64) - x0 + 0.5) / period)


# MARK: Colour

def lab_to_rgb(lab):
    """Linear Rec. 2020 of CIELAB with a D65 white of luminance 1 (the chart's white), shape (..., 3)."""
    lab = np.asarray(lab, dtype=np.float64)
    fy = (lab[..., 0] + 16) / 116
    f = np.stack([fy + lab[..., 1] / 500, fy, fy - lab[..., 2] / 200], axis=-1)
    xyz = np.where(f > 6 / 29, f ** 3, 3 * (6 / 29) ** 2 * (f - 4 / 29)) * D65
    return xyz @ XYZ_TO_REC2020.T


def rgb_to_lab(rgb):
    xyz = np.asarray(rgb, dtype=np.float64) @ REC2020_TO_XYZ.T / D65
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(np.maximum(xyz, 0)), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=-1)


def lch(L, C, h):
    h = np.radians(h)
    return lab_to_rgb(np.stack(np.broadcast_arrays(np.asarray(L, float), C * np.cos(h), C * np.sin(h)), axis=-1))


def edge_chroma(L, h):
    """The largest CIELAB chroma at lightness L and hue h (degrees) inside Rec. 2020's [0, 1] cube."""
    L, h = np.broadcast_arrays(np.asarray(L, float), np.asarray(h, float))
    lo, hi = np.zeros(L.shape), np.full(L.shape, 250.0)
    for _ in range(40):
        mid = (lo + hi) / 2
        rgb = lch(L, mid, h)
        inside = np.all((rgb >= 0) & (rgb <= 1), axis=-1)
        lo, hi = np.where(inside, mid, lo), np.where(inside, hi, mid)
    return lo


def truth(rgb):
    """A colour's ground truth: linear Rec. 2020, CIELAB (D65, white luminance 1) and luminance."""
    rgb = np.asarray(rgb, dtype=np.float64)
    lab = rgb_to_lab(rgb)
    return {"rgb": [round(float(v), 6) for v in rgb], "lab": [round(float(v), 3) for v in lab],
            "lch": [round(float(lab[0]), 3), round(float(np.hypot(lab[1], lab[2])), 3),
                    round(float(np.degrees(np.arctan2(lab[2], lab[1])) % 360), 3)],
            "luminance": round(float(rgb @ REC2020_Y), 6)}


# MARK: The chart

class Chart:
    def __init__(self, name, width, height, fill, description, questions, controls, primaries="Rec. 2020", tiff=False):
        self.name, self.description, self.questions, self.controls = name, description, questions, controls
        self.primaries, self.tiff = primaries, tiff
        self.img = np.empty((height, width, 3), np.float32)
        self.img[:] = fill
        self.background = truth(np.broadcast_to(np.asarray(fill, float), (3,)))
        self.regions = []

    def put(self, box, values, **fields):
        x0, y0, x1, y1 = (int(v) for v in box)
        values = np.asarray(values, dtype=np.float64)
        self.img[y0:y1, x0:x1] = values
        clipped = bool(np.any(values > 1) or np.any(values < 0))
        self.regions.append({"box": [x0, y0, x1, y1], **fields, **({"clipped": True} if clipped else {})})

    def pixels(self):
        return np.round(np.clip(self.img, 0, 1) * 65535).astype("<u2")

    def layout(self):
        h, w, _ = self.img.shape
        files = [f"{self.name}.dng"] + ([f"{self.name}.tif"] if self.tiff else [])
        return {"chart": self.name, "files": files, "width": w, "height": h,
                "encoding": ENCODING[self.primaries],
                **({"tiffEncoding": "16-bit TIFF, the same linear values encoded with the transfer curve of macOS's "
                                    "ITU-2020.icc, which is embedded"} if self.tiff else {}),
                "primaries": self.primaries, "white": 1.0, "midGrey": MID,
                "stops": "log2 of a value over middle grey 0.18, unless a field says otherwise",
                "box": "[x0, y0, x1, y1] in the chart's and the export's pixels, x1 and y1 exclusive",
                "rebuild": f"presence_charts.CHARTS['{self.name}']() in scripts/lightroom-probe",
                "description": self.description, "questions": self.questions, "controls": self.controls,
                "background": self.background, "regions": self.regions}


# MARK: Texture and Clarity: gratings, steps, colour and noise

PERIODS = [2 * 2 ** (k / 2) for k in range(19)]  # 2 to 1024 pixels in half-octave steps
AMPLITUDES = [0.05, 0.2, 0.8]
GRATING_MEANS = {"m4": -4.0, "m2": -2.0, "0": 0.0, "p1.5": 1.5}


def grating_cells():
    """(period, x0, x1) at full size. Periods to 256 pixels sit in the top half, 384-pixel cells to 128 and two
    or three periods beyond; the longer ones in the bottom half, two periods each. A whole period's cell ends
    where it starts, at the mean."""
    top, bottom, x = [], [], 0
    for p in (p for p in PERIODS if p <= 256):
        width = 384 if p <= 128 else round(p * (3 if p < 200 else 2))
        top.append((p, x, x + width))
        x += width
    x = 0
    for p in (p for p in PERIODS if p > 256):
        bottom.append((p, x, x + round(2 * p)))
        x += round(2 * p)
    return top, bottom


def grating(key, scale=1.0):
    mean = GRATING_MEANS[key]
    name = f"p-grating-{key}" + ("-half" if scale != 1.0 else "")
    W, H = round(6144 * scale), round(3072 * scale)
    c = Chart(name, W, H, stops(mean),
              f"Vertical sinusoidal gratings in log exposure around {mean:+g} stops: three bands of amplitude "
              f"{', '.join(f'{a:g}' for a in AMPLITUDES)} stops in each half, periods 2 to 256 pixels in the top half "
              f"and 362 to 1024 in the bottom half{', every length halved' if scale != 1.0 else ''}. "
              "Gain against period and amplitude.",
              [1, 3] if scale != 1.0 else [1], ["texture", "clarity"])
    half, band = H // 2, H // 6
    for cells, y0 in zip(grating_cells(), (0, half)):
        for i, a in enumerate(AMPLITUDES):
            ya, yb = y0 + i * band, y0 + (i + 1) * band
            end = 0
            for p, x0, x1 in cells:
                p, x0, x1 = p * scale, round(x0 * scale), round(x1 * scale)
                end = x1
                if p < 2:
                    c.put((x0, ya, x1, yb), stops(mean), kind="field", stops=mean,
                          note=f"a {p:.3g}-pixel period cannot be drawn; flat in the half-size chart")
                    continue
                values = stops(mean + a * sinusoid(np.arange(x0, x1), x0, p))
                c.put((x0, ya, x1, yb), values[None, :, None], kind="grating", axis="x", periodPx=p,
                      amplitudeStops=a, meanStops=mean, x0=x0,
                      value="0.18 * 2 ** (meanStops + amplitudeStops * sin(2 pi (x - x0 + 0.5) / periodPx)), x the column")
            c.put((end, ya, W, yb), stops(mean), kind="field", stops=mean)
    return c


STEP_GROUNDS = {"dark": -4.0, "middle": 0.0, "bright": 0.9}
STEP_SIZES = [0.25, 1.0, 3.0]


def steps(scale=1.0):
    name = "p-steps" + ("-half" if scale != 1.0 else "")
    W, H = round(4096 * scale), round(3072 * scale)
    c = Chart(name, W, H, stops(0.0),
              "Nine full-width bands, each a bar: ground - step/2 in the outer thirds and ground + step/2 in the middle "
              "third, so two edges a third of the width apart. Steps 0.25, 1 and 3 stops on dark (-4), middle (0) and "
              "bright (+0.9) grounds; the bright ground is 0.9, not 1.5, so the 3-stop bar stays under white. "
              "Halo width and overshoot." + (" Every length halved." if scale != 1.0 else ""),
              [2, 3] if scale != 1.0 else [2], ["texture", "clarity", "dehaze"])
    band = H // 9
    xa, xb = W // 3, 2 * W // 3
    for k, ((ground_name, ground), step) in enumerate((g, s) for g in STEP_GROUNDS.items() for s in STEP_SIZES):
        ya, yb = k * band, (H if k == 8 else (k + 1) * band)
        row = np.full(W, ground - step / 2)
        row[xa:xb] = ground + step / 2
        c.put((0, ya, W, yb), stops(row)[None, :, None], kind="bar", ground=ground_name, groundStops=ground,
              stepStops=step, lowStops=ground - step / 2, highStops=ground + step / 2, highColumns=[xa, xb],
              edges=f"between columns {xa - 1} and {xa} (rising) and {xb - 1} and {xb} (falling)")
    return c


COLOUR_GROUNDS = {"neutral": None, "red": 30.0, "orange": 60.0, "yellow": 95.0, "green": 150.0, "blue": 280.0,
                  "magenta": 330.0}
COLOUR_L, COLOUR_C, COLOUR_SWING = 50.0, 35.0, 15.0
COLOUR_PERIODS = [4, 16, 64, 256]


def colour_texture():
    W, H = 4096, 3328
    grey = lch(COLOUR_L, 0.0, 0.0)
    c = Chart("p-colour-texture", W, H, grey,
              "Rows 0-2687: for each of seven grounds at L* 50 (neutral, and chroma 35 at hues 30, 60, 95, 150, 280 and "
              "330), a luminance grating (every channel times 2 ** (0.2 sin), so chroma holds) and then a chroma "
              "grating at constant luminance (a swing of about 15 C* along the ground's own hue, with its luminance "
              "projected out), at periods 4, 16, 64 and 256 pixels in 1024-pixel cells. Rows 2688-3327: noise "
              "patches on middle grey. A luminance-only filter leaves the chroma gratings alone; a per-channel one "
              "does not.", [4, 5], ["texture", "clarity"])
    row = 192
    for k, (ground_name, hue) in enumerate(COLOUR_GROUNDS.items()):
        ground = grey if hue is None else lch(COLOUR_L, COLOUR_C, hue)
        far = lch(COLOUR_L, COLOUR_SWING, 0.0) if hue is None else lch(COLOUR_L, COLOUR_C + COLOUR_SWING, hue)
        swing = far - ground
        swing = swing - (swing @ REC2020_Y) / (ground @ REC2020_Y) * ground
        for j, kind in enumerate(("luminance", "chroma")):
            ya = (2 * k + j) * row
            for i, p in enumerate(COLOUR_PERIODS):
                x0, x1 = i * 1024, (i + 1) * 1024
                s = sinusoid(np.arange(x0, x1), x0, p)[None, :, None]
                if kind == "luminance":
                    values = ground * 2.0 ** (0.2 * s)
                    fields = {"amplitudeStops": 0.2,
                              "value": "ground * 2 ** (0.2 sin(2 pi (x - x0 + 0.5) / periodPx)) on every channel"}
                else:
                    values = ground + swing * s
                    fields = {"swing": [round(float(v), 6) for v in swing],
                              "value": "ground + swing * sin(2 pi (x - x0 + 0.5) / periodPx); swing has zero luminance",
                              "extremes": [truth(ground + swing), truth(ground - swing)]}
                c.put((x0, ya, x1, ya + row), values, kind=f"{kind} grating", ground=ground_name, groundTruth=truth(ground),
                      axis="x", periodPx=p, x0=x0, **fields)
    noise = [("luminance", 0.0, 0.05), ("luminance", 0.0, 0.1), ("luminance", 0.0, 0.2), ("luminance", 0.0, 0.4),
             ("luminance", -4.0, 0.2), ("chroma", 0.0, 0.1)]
    cell = W // len(noise)
    for i, (kind, mean, sigma) in enumerate(noise):
        x0, y0 = i * cell + (cell - 512) // 2, 2688 + 64
        seed = 101 + i
        rng = np.random.default_rng(seed)
        ground = stops(mean) * np.ones(3)
        if kind == "luminance":
            values = ground * 2.0 ** (sigma * rng.standard_normal((512, 512, 1)))
            value = "ground * 2 ** (sigmaStops * n), n standard normal per pixel, the same on every channel"
        else:
            e = rng.standard_normal((512, 512, 3))
            e -= (e @ (REC2020_Y / REC2020_Y.sum()))[..., None]
            values = ground * (1 + sigma * e)
            value = "ground * (1 + sigma * e), e standard normal per channel with its luminance taken out"
        c.put((x0, y0, x0 + 512, y0 + 512), values, kind=f"{kind} noise", meanStops=mean, sigma=sigma, seed=seed,
              value=value, rng="numpy.random.default_rng(seed).standard_normal, drawn as in presence_charts.colour_texture")
    return c


# MARK: Dehaze

def flat_grey():
    c = Chart("p-flat-grey", 3000, 2000, stops(0.0), "One flat field at middle grey: Dehaze with no structure at all.",
              [6], ["dehaze"])
    c.put((0, 0, 3000, 2000), stops(0.0), kind="field", stops=0.0)
    return c


def ramp_row(width, low=-12.0):
    """A smooth ramp from `low` stops under white to white, as the older charts' ramps."""
    return np.exp2(low * (1 - (np.arange(width) + 0.5) / width))


def dehaze_flat():
    W, H = 3000, 2000
    c = Chart("p-dehaze-flat", W, H, stops(0.0),
              "Rows 0-399: a smooth neutral ramp from 12 stops under white to white. Below, eight flat 750 x 800 fields: "
              "neutral at -4, -2, 0 and +1.5 stops, then L* 50 chroma 35 at hues 30, 60, 150 and 280. "
              "What Dehaze does to tone and colour with no texture.", [6], ["dehaze"])
    c.put((0, 0, W, 400), ramp_row(W)[None, :, None], kind="ramp", axis="x", stopsUnderWhite=[-12.0, 0.0],
          value="2 ** (-12 * (1 - (x + 0.5) / width)), x the column, the same on every channel")
    for i, s in enumerate([-4.0, -2.0, 0.0, 1.5]):
        c.put((i * 750, 400, (i + 1) * 750, 1200), stops(s), kind="field", stops=s, **truth(stops(s) * np.ones(3)))
    for i, h in enumerate([30.0, 60.0, 150.0, 280.0]):
        rgb = lch(COLOUR_L, COLOUR_C, h)
        c.put((i * 750, 1200, (i + 1) * 750, 2000), rgb, kind="field", **truth(rgb))
    return c


HAZE_SIZE = (4800, 3200)
AIRLIGHT = {"neutral": [0.72, 0.72, 0.72], "blue": [0.55, 0.70, 0.90], "warm": [0.88, 0.72, 0.50]}


def haze_texture(width, height, seed=11):
    """A haze-free scene: pink-noise log luminance (standard deviation 1.4 stops around middle grey) with smoother
    per-channel colour, so it has dark pixels, bright ones and colour at every scale."""
    rng = np.random.default_rng(seed)
    f = np.hypot(np.fft.rfftfreq(width)[None, :], np.fft.fftfreq(height)[:, None])
    f[0, 0] = 1.0

    def field(beta):
        spectrum = (rng.standard_normal(f.shape) + 1j * rng.standard_normal(f.shape)) / f ** beta
        spectrum[0, 0] = 0
        a = np.fft.irfft2(spectrum, s=(height, width))
        return (a - a.mean()) / a.std()

    lum = field(1.0)
    colour = np.stack([field(1.5) for _ in range(3)], axis=-1)
    return np.clip(MID * 2.0 ** (1.4 * lum[..., None] + 0.35 * colour), 2.0 ** -10, 0.9)


def haze(kind):
    W, H = HAZE_SIZE
    scene = haze_texture(W, H)
    t = 1 - 0.8 * (np.arange(W) + 0.5) / W
    name = f"p-haze-{kind}"
    if kind == "none":
        c = Chart(name, W, H, stops(0.0), "The haze-free scene J of the haze charts: pink-noise texture and colour "
                  "(haze_texture, seed 11). Dehaze where there is no haze.", [7], ["dehaze"])
        c.put((0, 0, W, H), scene, kind="scene", seed=11, value="haze_texture(4800, 3200, seed=11)")
        return c
    c = Chart(name, W, H, stops(0.0),
              "Synthetic haze I = J t + A (1 - t): J the scene of p-haze-none, t falling from 1 at the left edge to "
              f"0.2 at the right, A the airlight ({'blue in the top half and warm in the bottom half' if kind == 'two' else kind}).",
              [7], ["dehaze"])
    regions = [("blue", 0, H // 2), ("warm", H // 2, H)] if kind == "two" else [(kind, 0, H)]
    for air, y0, y1 in regions:
        A = np.array(AIRLIGHT[air])
        values = scene[y0:y1] * t[None, :, None] + A * (1 - t)[None, :, None]
        c.put((0, y0, W, y1), values, kind="haze", airlightName=air, airlight=AIRLIGHT[air], airlightTruth=truth(A),
              seed=11, transmission="1 - 0.8 * (x + 0.5) / width, x the column",
              value="J * t + airlight * (1 - t), J = haze_texture(4800, 3200, seed=11) at the same pixel")
    return c


def locality(scale=1.0):
    """The 2026-10-29 locality chart (make_charts.locality), squares 8 to 512 pixels on three surrounds, as its own
    Presence chart so Dehaze's locality can be read beside the Light controls'. In linear sRGB like the original."""
    pixels, old = make_charts.locality(scale)
    name = "p-locality" + ("-half" if scale != 1.0 else "")
    h, w, _ = pixels.shape
    c = Chart(name, w, h, 0.0, "The locality chart of 2026-10-29 (make_charts.locality): rows of squares 8 to 512 "
              "pixels on dark, mid and bright surrounds under a 12-stop ramp. Stops here are under the chart's white."
              + (" Every length halved." if scale != 1.0 else ""), [8], ["dehaze"], primaries="sRGB")
    c.img = pixels.astype(np.float32) / 65535
    band = old["ramp"]["band"]
    c.regions.append({"box": [0, band[0], w, band[1]], "kind": "ramp", "axis": "x", "stopsUnderWhite": [-12.0, 0.0],
                      "value": "2 ** (-12 * (1 - (x + 0.5) / width))"})
    for row in old["rows"]:
        c.regions.append({"box": [0, row["band"][0], w, row["band"][1]], "kind": "surround", "name": row["name"],
                          "stopsUnderWhite": row["surroundStops"]})
    for sq in old["squares"]:
        c.regions.append({"box": sq["box"], "kind": "square", "row": sq["row"], "sizePx": sq["size"],
                          "stopsUnderWhite": sq["stops"], "surroundStopsUnderWhite": sq["surroundStops"]})
    return c


# MARK: Vibrance and Saturation

GRID_L = [20.0, 35.0, 50.0, 65.0, 80.0]
GRID_HUES = [15.0 * k for k in range(24)]
SKIN_HUES = [h for h in np.arange(20.0, 80.01, 2.5) if h % 15]
GRID_STEPS = 8
NEUTRAL_L = [2.0] + [5.0 * k for k in range(1, 20)] + [98.0]
EXTREME_L = [3.0, 6.0, 92.0, 96.0]
PRIMARIES = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [0, 1, 1], [1, 0, 1],
             [0.5, 0, 0], [0, 0.5, 0], [0, 0, 0.5], [0.5, 0.5, 0], [0, 0.5, 0.5], [0.5, 0, 0.5]]
PITCH, PATCH = 56, 48


def colour_grid():
    W, H = 4096, 3072
    grey = lch(50.0, 0.0, 0.0)
    c = Chart("p-colour-grid", W, H, grey,
              "48-pixel patches on L* 50 grey, 56 apart. Main grid: 24 hues (every 15 degrees of CIELAB hue) by 8 chroma "
              "steps (1/8 to 8/8 of the most Rec. 2020 holds at that hue and lightness) at L* 20, 35, 50, 65 and 80. Skin "
              "grid: the same at hues 20 to 80 every 2.5 degrees, less the multiples of 15. Neutrals at L* 2 to 98. "
              "Extremes: the gamut's edge at L* 3, 6, 92 and 96 for the 24 hues, and the primaries and secondaries at "
              "full and half. Ramps: hue all round at L* 50 and 70, at chroma 30 and at 0.95 of the edge; chroma from 0 "
              "to the edge at L* 55 for 12 hues. As a DNG and as a TIFF with the same values.",
              [9, 10], ["vibrance", "saturation"], tiff=True)

    def patch(x, y, rgb, **fields):
        c.put((x + 4, y + 4, x + 4 + PATCH, y + 4 + PATCH), rgb, kind="patch", **fields, **truth(rgb))

    def block(x, y, L, hues, group):
        edges = edge_chroma(L, np.array(hues))
        for i, h in enumerate(hues):
            for j in range(GRID_STEPS):
                C = edges[i] * (j + 1) / GRID_STEPS
                patch(x + i * PITCH, y + j * PITCH, lch(L, C, h), group=group, nominal={"L": L, "C": round(float(C), 3),
                      "h": float(h), "fractionOfEdge": (j + 1) / GRID_STEPS})

    for k, L in enumerate(GRID_L):
        r, col = divmod(k, 3)
        block(16 + col * (24 * PITCH + 24), 16 + r * (8 * PITCH + 24), L, GRID_HUES, "grid")
    for k, L in enumerate(GRID_L):
        r, col = divmod(k, 3)
        block(16 + col * (len(SKIN_HUES) * PITCH + 24), 960 + r * (8 * PITCH + 24), L, SKIN_HUES, "skin")
    y = 1904
    for i, L in enumerate(NEUTRAL_L):
        patch(16 + i * PITCH, y, lch(L, 0.0, 0.0), group="neutral", nominal={"L": L, "C": 0.0})
    extremes = [(L, h) for L in EXTREME_L for h in GRID_HUES]
    for i, (L, h) in enumerate(extremes):
        r, col = divmod(i, 72)
        C = float(edge_chroma(L, h))
        patch(16 + col * PITCH, 1984 + r * PITCH, lch(L, C, h), group="extreme", nominal={"L": L, "C": round(C, 3), "h": h,
              "fractionOfEdge": 1.0})
    for i, rgb in enumerate(PRIMARIES):
        patch(16 + (24 + i) * PITCH, 1984 + PITCH, np.array(rgb, float), group="primary")
    x0, x1 = 16, W - 16
    hue = 360 * (np.arange(x0, x1) - x0 + 0.5) / (x1 - x0)
    y = 2120
    for L, how in [(50.0, 30.0), (50.0, "edge"), (70.0, 30.0), (70.0, "edge")]:
        C = 0.95 * edge_chroma(L, hue) if how == "edge" else np.full(hue.shape, how)
        c.put((x0, y, x1, y + 64), lch(L, C, hue)[None], kind="hue ramp", L=L,
              chroma="0.95 of the edge at each hue" if how == "edge" else how,
              value="hue = 360 (x - x0 + 0.5) / (x1 - x0) degrees of CIELAB hue, x the column")
        y += 64
    y = 2400
    for h in range(0, 360, 30):
        edge = float(edge_chroma(55.0, h))
        C = edge * (np.arange(x0, x1) - x0 + 0.5) / (x1 - x0)
        c.put((x0, y, x1, y + 48), lch(55.0, C, float(h))[None], kind="chroma ramp", L=55.0, h=float(h), edgeChroma=round(edge, 3),
              value="C = edgeChroma (x - x0 + 0.5) / (x1 - x0), x the column")
        y += 48
    return c


def itu2020_encode(linear):
    """The inverse of ITU-2020.icc's tone curve (type 3, g 2.2222, a 0.90967, b 0.09033, c 0.22223, d 0.081), so a
    TIFF tagged with that profile decodes to `linear`."""
    g, a, b, cc, d = 2.22222900390625, 0.90966796875, 0.09033203125, 0.22222900390625, 0.08099365234375
    linear = np.clip(linear, 0, 1)
    return np.where(linear >= cc * d, (np.power(linear, 1 / g) - b) / a, linear / cc)


# MARK: The composite chart for the combinations

def combo():
    W, H = 3584, 2400
    c = Chart("p-combo", W, H, stops(0.0),
              "One frame with something for every control, for the combinations: rows 0-239 a neutral 12-stop ramp; "
              "240-719 gratings of 0.2 stop at middle grey, periods 4, 16, 64 and 256 pixels, then flat grey; 720-1199 "
              "1-stop bars on dark, middle and bright grounds; 1200-1679 patches at L* 50, 24 hues at half and 0.95 of "
              "the edge; 1680-2399 the haze scene with neutral airlight, transmission 1 to 0.2 left to right.",
              [1, 2, 6, 7, 9], ["texture", "clarity", "dehaze", "vibrance", "saturation"])
    c.put((0, 0, W, 240), ramp_row(W)[None, :, None], kind="ramp", axis="x", stopsUnderWhite=[-12.0, 0.0],
          value="2 ** (-12 * (1 - (x + 0.5) / width))")
    for i, p in enumerate(COLOUR_PERIODS):
        x0, x1 = i * 768, (i + 1) * 768
        c.put((x0, 240, x1, 720), stops(0.2 * sinusoid(np.arange(x0, x1), x0, p))[None, :, None], kind="grating",
              axis="x", periodPx=p, amplitudeStops=0.2, meanStops=0.0, x0=x0,
              value="0.18 * 2 ** (0.2 sin(2 pi (x - x0 + 0.5) / periodPx))")
    c.put((3072, 240, W, 720), stops(0.0), kind="field", stops=0.0)
    third = W // 3
    for i, (ground_name, ground) in enumerate(STEP_GROUNDS.items()):
        x0, x1 = i * third, (W if i == 2 else (i + 1) * third)
        row = np.full(x1 - x0, ground - 0.5)
        a, b = (x1 - x0) // 3, 2 * (x1 - x0) // 3
        row[a:b] = ground + 0.5
        c.put((x0, 720, x1, 1200), stops(row)[None, :, None], kind="bar", ground=ground_name, groundStops=ground,
              stepStops=1.0, lowStops=ground - 0.5, highStops=ground + 0.5, highColumns=[x0 + a, x0 + b])
    col = W // 24
    for i, h in enumerate(GRID_HUES):
        edge = float(edge_chroma(50.0, h))
        for j, frac in enumerate((0.5, 0.95)):
            rgb = lch(50.0, frac * edge, h)
            x0, y0 = i * col + 8, 1200 + j * 240 + 8
            c.put((x0, y0, x0 + col - 16, y0 + 224), rgb, kind="patch", nominal={"L": 50.0, "C": round(frac * edge, 3),
                  "h": h, "fractionOfEdge": frac}, **truth(rgb))
    scene = haze_texture(W, 720, seed=12)
    t = 1 - 0.8 * (np.arange(W) + 0.5) / W
    A = np.array(AIRLIGHT["neutral"])
    c.put((0, 1680, W, H), scene * t[None, :, None] + A * (1 - t)[None, :, None], kind="haze", airlight=AIRLIGHT["neutral"],
          seed=12, transmission="1 - 0.8 * (x + 0.5) / width", value="haze_texture(3584, 720, seed=12) * t + airlight * (1 - t)")
    return c


# MARK: Round 2: Clarity's frame adaptation, and detail beside a strong edge

TONE_SIZE = (6144, 3072)
TONE_MEANS = [-4.0, -2.0, 0.0, 1.5]
TONE_PERIOD, TONE_AMPLITUDE, TONE_CELL = 64, 0.05, (1280, 512)
TONE_GROUNDS = {"dark": -6.0, "bright": 2.0}


def tone_box(slot):
    """The grating cell of slot 0 to 3, left to right: 1280 x 512 (20 periods) in the middle of its quarter of the
    width and of the height. The alone-frames keep slot 2's box, so their grating is the four-chart's 0-stop one."""
    W, H = TONE_SIZE
    w, h = TONE_CELL
    x0, y0 = slot * (W // 4) + (W // 4 - w) // 2, (H - h) // 2
    return x0, y0, x0 + w, y0 + h


def tone_grating(c, slot, mean):
    x0, y0, x1, y1 = tone_box(slot)
    values = stops(mean + TONE_AMPLITUDE * sinusoid(np.arange(x0, x1), x0, TONE_PERIOD))
    c.put((x0, y0, x1, y1), values[None, :, None], kind="grating", axis="x", periodPx=TONE_PERIOD,
          amplitudeStops=TONE_AMPLITUDE, meanStops=mean, x0=x0,
          value="0.18 * 2 ** (meanStops + amplitudeStops * sin(2 pi (x - x0 + 0.5) / periodPx)), x the column")


def tone(ground):
    """F1's request 1: the 0.05-stop, 64-pixel grating at four mean levels in one frame (`four`), and its 0-stop cell
    alone on a frame that is otherwise all dark, all bright or a 12-stop ramp."""
    W, H = TONE_SIZE
    name = f"q-tone-{ground}"
    questions, controls = ["Clarity's frame adaptation against tone (F1 request 1)"], ["clarity"]
    if ground == "four":
        c = Chart(name, W, H, stops(0.0),
                  "Four vertical sinusoidal gratings in log exposure, 0.05 stop, period 64 pixels, 1280 x 512 each (20 "
                  "periods), at mean -4, -2, 0 and +1.5 stops left to right, each in the middle of its quarter of the "
                  "width, on a middle-grey field. The same local input at four levels in one frame.",
                  questions, controls)
        for slot, mean in enumerate(TONE_MEANS):
            tone_grating(c, slot, mean)
        return c
    x0, y0, x1, y1 = tone_box(2)
    if ground in TONE_GROUNDS:
        level = TONE_GROUNDS[ground]
        c = Chart(name, W, H, stops(level),
                  f"q-tone-four's 0-stop grating alone, in the same box, on a field of {level:+g} stops: the same pixels "
                  "in a frame whose other content is all " + ("dark." if level < 0 else "bright."), questions, controls)
    else:
        ramp = ramp_row(W)
        under = np.log2(ramp[[x0, x1 - 1]])
        c = Chart(name, W, H, stops(0.0),
                  "q-tone-four's 0-stop grating alone, in the same box, on a smooth neutral ramp from 12 stops under white "
                  f"to white across the width (as p-dehaze-flat's). Beside the grating the ramp is {under[0]:.2f} stops "
                  f"under white at its left edge and {under[1]:.2f} at its right (middle grey is {np.log2(MID):.2f}).",
                  questions, controls)
        c.img[:] = ramp[None, :, None]
        c.background = None
        value = "2 ** (-12 * (1 - (x + 0.5) / width)), x the column, the same on every channel"
        for box in ((0, 0, W, y0), (0, y1, W, H), (0, y0, x0, y1), (x1, y0, W, y1)):
            c.put(box, ramp[box[0]:box[2]][None, :, None], kind="ramp", axis="x", stopsUnderWhite=[-12.0, 0.0], value=value)
    tone_grating(c, 2, 0.0)
    return c


EDGE_SIZE = (6144, 3072)
EDGE_STEP, EDGE_AMPLITUDE, EDGE_PERIODS = 3.0, 0.25, [8, 32]


def edge():
    """F1's request 2: 0.25-stop gratings at 8 and 32 pixels riding a 3-stop bar at 0 stops, so each grating borders
    the bar's two edges on their dark and bright sides; a third band holds the bar alone, the edge's own halo."""
    W, H = EDGE_SIZE
    band = H // 3
    xa, xb = W // 3, 2 * W // 3
    low, high = -EDGE_STEP / 2, EDGE_STEP / 2
    c = Chart("q-edge", W, H, stops(0.0),
              f"Three full-width bands of {band} rows, each a bar of {EDGE_STEP:g} stops around middle grey ({low:+g} "
              f"stops in the outer thirds, {high:+g} in the middle third, so edges at columns {xa} and {xb}). The top "
              f"two carry a vertical sinusoidal grating of {EDGE_AMPLITUDE:g} stop in log exposure across the whole "
              f"width, period {EDGE_PERIODS[0]} and then {EDGE_PERIODS[1]} pixels; the bottom band is the bar alone. "
              "Texture's and Clarity's gain on detail as a function of the distance to a strong edge, on both sides.",
              ["Texture and Clarity beside a strong edge (F1 request 2)"], ["texture", "clarity"])
    bar = np.full(W, low)
    bar[xa:xb] = high
    fields = {"groundStops": 0.0, "stepStops": EDGE_STEP, "lowStops": low, "highStops": high, "highColumns": [xa, xb],
              "edges": f"between columns {xa - 1} and {xa} (rising) and {xb - 1} and {xb} (falling)"}
    for k, period in enumerate(EDGE_PERIODS):
        s = bar + EDGE_AMPLITUDE * sinusoid(np.arange(W), 0, period)
        c.put((0, k * band, W, (k + 1) * band), stops(s)[None, :, None], kind="bar grating", axis="x", periodPx=period,
              amplitudeStops=EDGE_AMPLITUDE, x0=0, **fields,
              value="0.18 * 2 ** (bar(x) + amplitudeStops * sin(2 pi (x - x0 + 0.5) / periodPx)), bar(x) highStops on "
                    "highColumns and lowStops elsewhere, x the column")
    c.put((0, 2 * band, W, H), stops(bar)[None, :, None], kind="bar", ground="middle", **fields)
    return c


# MARK: Round 3: a white object brighter than the haze, and a photograph rendered with no colour table

WHITE_BOX, WHITE_VALUE = (4600, 1600, 4664, 1664), 0.95


def haze_white():
    """F2's request 4: p-haze-neutral with a 64 x 64 patch of 0.95 on every channel in its haziest strip, brighter than
    the airlight (0.72) and than the hazy scene around it."""
    c = haze("neutral")
    x0, y0, x1, y1 = WHITE_BOX
    t = 1 - 0.8 * (np.arange(x0, x1) + 0.5) / HAZE_SIZE[0]
    c.name = "r-haze-white"
    c.description += (f" A {x1 - x0} x {y1 - y0} patch of {WHITE_VALUE} on every channel replaces the haze at "
                      f"{list(WHITE_BOX)}, where the transmission is {t[0]:.3f} to {t[-1]:.3f}: a white object brighter "
                      "than the airlight.")
    c.questions = ["Dehaze on a white object brighter than the haze (F2 request 4)"]
    c.put(WHITE_BOX, [WHITE_VALUE] * 3, kind="white patch", value=WHITE_VALUE, truth=truth([WHITE_VALUE] * 3))
    return c


# Lightroom sees the sky raw at this multiple of the spike's decode, in a LinearRaw DNG's units. Measured on round 1's
# bases: Lightroom's DNG tone curve read from p-colour-grid's 21 neutrals and undone on p-photo-sky's base, over the
# decode, gives a median of 0.5435 on 64-pixel blocks (10th to 90th percentile 0.524 to 0.555, the same from the
# shadows to the sky).
SKY_SCALE = 0.5435
SKY_DECODE = ("--no-lens", "--nr", 0, "--luma-nr", 0)


def sky_matrix():
    """F2's request 3 with no colour table: p-photo-sky's raw decoded by argent-spike into linear Rec. 2020, scaled by
    SKY_SCALE and written as a LinearRaw DNG. Lightroom renders it as it renders the charts, through the Embedded
    profile, a matrix with no hue map and no look table, at the level it renders the ARW. Every profile Lightroom
    ships for the a7 IV has a look table, so a camera raw cannot be rendered without one."""
    # The main checkout's spike, stock and corpus, imported here because presence_plan imports this module.
    import presence_plan
    import scene_io
    raw = presence_plan.CORPUS / presence_plan.PHOTOS["sky"][0]
    scene = scene_io.scene_of(raw, presence_plan.STOCK, *SKY_DECODE, binary=presence_plan.SPIKE) * np.float32(SKY_SCALE)
    h, w, _ = scene.shape
    over = float(np.mean(scene.max(axis=-1) > 1))
    c = Chart("r-sky-matrix", w, h, 0.0,
              f"The photograph of p-photo-sky ({raw.name}): a sunlit rock dome and bare trees under a blue sky. Decoded "
              f"by argent-spike {' '.join(str(a) for a in SKY_DECODE)} (Apple's decoder, As Shot white balance, no lens "
              f"correction, no noise reduction) into linear Rec. 2020, times {SKY_SCALE}, so that Lightroom's raw tone "
              f"curve sees it at the level it sees the ARW. {over:.4%} of pixels had a channel over 1 and are clipped "
              "to it. Rendered through the Embedded profile, a matrix with no hue map and no look table.",
              ["Where the sky's hue turn under Dehaze comes from (F2 request 3)"], ["dehaze"])
    c.background = None
    c.put((0, 0, w, h), np.minimum(scene, 1.0), kind="photograph", source=str(raw), scale=SKY_SCALE,
          decode=f"argent-spike {raw.name} --stock {presence_plan.STOCK.name} {' '.join(str(a) for a in SKY_DECODE)} "
                 "--scene-out", pixelsOverWhite=over,
          value="min(1, scale * the decode's scene), linear Rec. 2020 with a D65 white")
    return c


CHARTS = {
    **{f"p-grating-{k}": (lambda k=k: grating(k)) for k in GRATING_MEANS},
    "p-grating-0-half": lambda: grating("0", 0.5),
    "p-steps": steps,
    "p-steps-half": lambda: steps(0.5),
    "p-colour-texture": colour_texture,
    "p-flat-grey": flat_grey,
    "p-dehaze-flat": dehaze_flat,
    **{f"p-haze-{k}": (lambda k=k: haze(k)) for k in ("none", "neutral", "blue", "warm", "two")},
    "p-locality": locality,
    "p-locality-half": lambda: locality(0.5),
    "p-colour-grid": colour_grid,
    "p-combo": combo,
    **{f"q-tone-{g}": (lambda g=g: tone(g)) for g in ("four", "dark", "bright", "ramp")},
    "q-edge": edge,
    "r-haze-white": haze_white,
    "r-sky-matrix": sky_matrix,
}
# Charts made from a photograph's decode, which needs the main checkout's spike: the tests build every other chart.
DECODED = {"r-sky-matrix"}
MATRICES = {"Rec. 2020": [round(float(v), 7) for v in (XYZ_TO_REC2020).ravel()], "sRGB": make_charts.XYZ_TO_SRGB}


def write(name, out):
    """Writes chart `name` into `out` (its DNG, and its TIFF for the colour grid) and returns its layout."""
    chart = CHARTS[name]()
    pixels = chart.pixels()
    make_charts.write_dng(out / f"{name}.dng", pixels, MATRICES[chart.primaries])
    if chart.tiff:
        encoded = np.round(itu2020_encode(pixels.astype(np.float64) / 65535) * 65535).astype("<u2")
        make_charts.write_chart_tiff(out / f"{name}.tif", encoded, ITU2020_ICC)
    return chart.layout()
