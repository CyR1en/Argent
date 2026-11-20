"""The Presence probe: every Lightroom job for Texture, Clarity, Dehaze, Vibrance and Saturation, and the manifest
of what came out.

    python -I presence_plan.py list [--round N]          each job, its renders and the disk its exports will take
    python -I presence_plan.py write JOB [JOB ...]       writes the jobs into the plug-in's folder (READY needed); a
                                                         job already run is skipped. Then `jobs.py run`.
    python -I presence_plan.py manifest OUT [--round N]  reads every export back and writes OUT/manifest.json and
                                                         OUT/manifest.md: paths, settings asked and applied, sanity;
                                                         round 2's also holds each photograph's frame measures
    python -I presence_plan.py frames OUT                measures every candidate photograph from a quick decode and
                                                         writes OUT/frame-candidates.json and .md, in the order the
                                                         spread-out choice of round 2 takes them

Round 1 (p-) is the matrix of 2026-11-11 morning. Round 2 (q-) is the fit agent F1's three requests (Clarity's frame
adaptation, detail beside an edge, the order of Texture and Clarity) and twenty more photographs at Clarity and
Texture, for holdout tests and for Clarity's frame statistic. Round 3 (r-) is F2's four Dehaze requests (the curve
between the knots, a crop, the sky under a profile with no colour table, a white object brighter than the haze), F3's
three colour requests (Exposure beside Saturation and Vibrance, Vibrance between the knots) and round 2's twenty frames
at Dehaze, Vibrance and Saturation, held out from those fits. `write` takes shell patterns (`'r-photo-*'`).

A job renders one source: the probe raw, a chart of `make_charts.py presence` (references/lightroom-probe/p-charts),
or a photograph. Its items are the base and each setting, named <job>_<label>, cloned into inputs/<job>/ and exported
to exports-<job>/<job>_<label>.tif. Raws get the neutral sidecar and Adobe Standard (jobs.clone, jobs.settings_for).
"""
import argparse
import fnmatch
import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jobs  # noqa: E402
import presence_charts  # noqa: E402
import presence_stats  # noqa: E402
import probe  # noqa: E402
import scene_io  # noqa: E402

DATA = jobs.jobs_dir().parent
CHARTS = DATA / "p-charts"
Q_CHARTS = DATA / "q-charts"
CORPUS = DATA.parent / "corpus"
PROBE_RAW = DATA / "raw" / "raw_00_base.ARW"
RAW_SIZE = (7008, 4672)
# The checkout whose references the plug-in reads. Its built spike decodes the candidate photographs, read only.
MAIN = DATA.parents[1]
SPIKE = MAIN / ".build" / "release" / "argent-spike"
STOCK = MAIN / "build" / "stocks" / "kodak-portra-400"
SAMPLES = MAIN / "samples"
PROBE_SOURCE = SAMPLES / "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"  # PROBE_RAW is its clone

RAW_VALUES = [-100, -75, -50, -25, -10, 10, 25, 50, 75, 100]
CHART_VALUES = [-100, -50, -25, 25, 50, 100]
PHOTO_VALUES = [-100, -50, 50, 100]
SHORT = {"texture": "tex", "clarity": "cla", "dehaze": "deh", "vibrance": "vib", "saturation": "sat"}


def combo(*parts):
    """('tex', 50), ('ex', -1) ... -> ('tex+50_ex-1', {crs key: value})."""
    keys = {**{v: jobs.KEYS[k] for k, v in SHORT.items()}, "ex": "Exposure2012", "co": "Contrast2012",
            "hl": "Highlights2012", "sh": "Shadows2012"}
    return "_".join(f"{k}{v:+g}" for k, v in parts), {keys[k]: f"{v:g}" for k, v in parts}


# The order of operations: each pair against its singles. Presence controls at 50, so neither clips.
COMBOS = [combo(*c) for c in [
    (("tex", 50), ("cla", 50)), (("cla", 50), ("co", 50)),
    (("tex", 50), ("ex", -1)), (("tex", 50), ("ex", 1)), (("cla", 50), ("ex", -1)), (("cla", 50), ("ex", 1)),
    (("deh", 50), ("ex", -1)), (("deh", 50), ("ex", 1)), (("deh", 50), ("sat", 50)),
    (("vib", 50), ("sat", 50)), (("vib", -50), ("sat", -50)), (("vib", 50), ("sat", -50)), (("vib", -50), ("sat", 50)),
    (("sat", 50), ("co", 50)), (("vib", 50), ("co", 50)), (("sat", 50), ("ex", 1)), (("vib", 50), ("ex", 1)),
    (("deh", 50), ("hl", -100)), (("deh", 50), ("sh", 100))]]
TONE_SINGLES = [combo(c) for c in [("ex", -1), ("ex", 1), ("co", 50), ("hl", -100), ("sh", 100)]]
PRESENCE_SINGLES = [combo(c) for c in [("tex", 50), ("cla", 50), ("deh", 50), ("vib", 50), ("vib", -50), ("sat", 50),
                                       ("sat", -50)]]

# Chosen by eye from contact sheets of the 74 raws in references/corpus and samples/ (all Sony a7 IV).
PHOTOS = {
    "hazy": ("imaging-resource-a7iv-gallery/Y-JG-A7-IV-FE-24-105-4854.ARW",
             "hazy landscape: fog over a rocky shore and the sea behind lupines; the haziest frame in the corpus, whose "
             "haze is sea fog (4830 and 4834 have lighter fog, DSC00424 and DSC00426 are foggy woods)"),
    "sky": ("imaging-resource-a7iv-gallery/Y-JG-A7-IV-FE-24-105-0520.ARW",
            "clear landscape with sky: a sunlit rock dome and bare trees under a blue sky with clouds"),
    "skin": ("imaging-resource-a7iv-gallery/Y-JG-SONY-A7-IV-1839.ARW",
             "stand-in for a portrait, which the corpus lacks (no frame shows human skin): a red squirrel whose orange "
             "fur sits in the skin hues Vibrance protects; p-colour-grid samples those hues every 2.5 degrees"),
    "saturated": ("imaging-resource-a7iv-wayback/A7M4hSLI000100NR0.ARW",
                  "saturated colours: Imaging Resource's still life at ISO 100, a fan of dyed fabric, embroidery thread, "
                  "crayons, bottles and a ColorChecker"),
    "foliage": ("photographyblog-a7iv/sony_a7_iv_48.arw", "foliage: autumn trees and shrubs over a pond, greens and yellows"),
    "texture": ("photographyblog-a7iv/sony_a7_iv_38.arw", "fine texture: tree roots and bark in leaf litter"),
    "iso": ("imaging-resource-a7iv-wayback/A7M4hSLI025600NR0.ARW",
            "high ISO: the same still life at ISO 25600, so noise can be told from content against the ISO 100 frame"),
    "night": ("imaging-resource-a7iv-gallery/Y-JG-SONY-A7-IV-1616.ARW",
              "night scene: a harbour at dusk under a dark blue sky with lit buildings and boats, ISO 6400"),
    "flat": ("imaging-resource-a7iv-gallery/Y-JG-SONY-A7-IV-1455.ARW",
             "low contrast: an overcast harbour that never reaches white (a scene of the Light controls probe too)"),
    "contrast": ("imaging-resource-a7iv-gallery/Y-JG-SONY-A7-IV-0602.ARW",
                 "high contrast: a sunset sky over black tree silhouettes (a scene of the Light controls probe too)"),
}

# Which controls each chart answers for (presence_charts' layouts say the same).
CHART_CONTROLS = {
    **{f"p-grating-{k}": ["texture", "clarity"] for k in ("m4", "m2", "0", "p1.5", "0-half")},
    "p-steps": ["texture", "clarity", "dehaze"], "p-steps-half": ["texture", "clarity", "dehaze"],
    "p-colour-texture": ["texture", "clarity"],
    **{name: ["dehaze"] for name in ("p-flat-grey", "p-dehaze-flat", "p-haze-none", "p-haze-neutral", "p-haze-blue",
                                     "p-haze-warm", "p-haze-two", "p-locality", "p-locality-half")},
    "p-colour-grid": ["vibrance", "saturation"],
}


@dataclass(frozen=True)
class Job:
    name: str
    source: Path
    kind: str  # probe raw, chart or photo
    items: tuple  # (label, {crs key: value}), the base first
    why: str
    layout: str = None  # the chart's name, for its layout file
    size: tuple = RAW_SIZE
    controls: tuple = field(default=())
    twin: str = None  # an earlier job of the same source, whose base this job's base should equal bit for bit

    def stem(self, label):
        return f"{self.name}_{label}"

    def export(self, label):
        return DATA / f"exports-{self.name}" / f"{self.stem(label)}.tif"

    def bytes(self):
        return len(self.items) * (self.size[0] * self.size[1] * 6 + 8192)


def singles(controls, values):
    return (("00_base", {}),) + tuple((f"{c}_{v:+d}", {jobs.KEYS[c]: f"{v:g}"}) for c in controls for v in values)


def chart_size(name, folder=CHARTS):
    layout = json.loads((folder / f"{name}-layout.json").read_text())
    return layout["width"], layout["height"]


def plan():
    out = [Job("p-raw", PROBE_RAW, "probe raw", singles(jobs.PRESENCE, RAW_VALUES),
               "the probe raw of the Light controls (samples/ILCE-7M4_DSC06674), each control at ten values",
               controls=tuple(jobs.PRESENCE))]
    for name, controls in CHART_CONTROLS.items():
        out.append(Job(name, CHARTS / f"{name}.dng", "chart", singles(controls, CHART_VALUES),
                       f"chart {name} for {', '.join(controls)}", name, chart_size(name), tuple(controls)))
    out.append(Job("p-colour-grid-tif", CHARTS / "p-colour-grid.tif", "chart", singles(["vibrance", "saturation"], CHART_VALUES),
                   "the colour grid as a 16-bit TIFF, which Lightroom renders as a finished picture", "p-colour-grid",
                   chart_size("p-colour-grid"), ("vibrance", "saturation")))
    for key, (path, why) in PHOTOS.items():
        out.append(Job(f"p-photo-{key}", CORPUS / path, "photo", singles(jobs.PRESENCE, PHOTO_VALUES), why,
                       controls=tuple(jobs.PRESENCE)))
    out.append(Job("p-raw-combos", PROBE_RAW, "probe raw", (("00_base", {}),) + tuple(TONE_SINGLES) + tuple(COMBOS),
                   "the probe raw with pairs of controls, for the order of operations; its Presence singles at +-50 are p-raw's"))
    out.append(Job("p-combo", CHARTS / "p-combo.dng", "chart",
                   (("00_base", {}),) + tuple(PRESENCE_SINGLES) + tuple(TONE_SINGLES) + tuple(COMBOS),
                   "the composite chart with every single and every pair", "p-combo", chart_size("p-combo")))
    return out


# MARK: Round 2

TONE_VALUES = [-100, -50, 50, 100]
PAIR = combo(("tex", 100), ("cla", 100))
# F1 asks for the pair at +100 on p-combo and the probe raw, whose 0.2-stop gratings and photograph reach the knee only
# after the first slider; p-grating-0's 0.8-stop bands are in it from the start, so the pair is rendered there too.
# q-raw's base came out 0.70 codes from p-raw's on average (12 % of codes differ, most in the darks; measured), so the
# singles are rendered again beside each pair, and q-raw-repeat renders the probe raw's base twice in one run.
TWINS = {"q-combo": "p-combo", "q-raw": "p-raw", "q-grating-0": "p-grating-0", "q-raw-repeat": "q-raw"}
PHOTO_CLARITY = [-100, -50, 50, 100]
PHOTO_TEXTURE = [-100, 100]

# The first 20 of `frames`' order (frame-candidates.md): 4901 on purpose, then each frame farthest from round 1's
# photographs and from the frames before it in median, spread and detail, one frame a scene. Described by eye from the
# quick decode. Paths under references/corpus.
GALLERY, BLOG = "imaging-resource-a7iv-gallery/", "photographyblog-a7iv/"
PHOTOS_Q = {
    "horizon": (GALLERY + "Y-JG-A7-IV-FE-24-105-4901.ARW",
                "taken on purpose: lupines by the sea under a bright overcast sky, with wooded islands and a far shore at "
                "the horizon that are lighter than the near trees (a strip of the middle island -0.7 stops against -2.35 "
                "on the quick decode, measured) and bluer (by eye): the corpus's only distant atmospheric haze, on a thin "
                "strip; also the widest spread"),
    "mirror-lights": (BLOG + "sony_a7_iv_09.arw", "pick 2: a mirrored room of small green and white lights in the dark; "
                      "the darkest median and the most fine and coarse detail of any candidate"),
    "magenta-night": (BLOG + "sony_a7_iv_71.arw", "pick 3: a building lit magenta at night behind trees; dark, with a "
                      "narrow spread for its level and one saturated hue"),
    "hall": (BLOG + "sony_a7_iv_16.arw", "pick 4: the Turbine Hall down its length, a dark interior under a bright "
             "skylight; dark with a wide spread and strong coarse detail"),
    "fog-woods": (GALLERY + "Y-WB-Sigma60_600_BETA-DSC00426.ARW", "pick 5: bare woods in fog (near fog, not distant haze), "
                  "portrait orientation; the narrowest spread of any candidate"),
    "dog-snow": (GALLERY + "Y-JG-SONY-A7-IV-0273.ARW", "pick 6: a black and white dog on grey snow; the brightest median of "
                 "any candidate, with a narrow spread"),
    "gull-flight": (GALLERY + "Y-JG-SONY-A7-IV-1040.ARW", "pick 7: a gull flying past a dark wooded bank under a blown sky; "
                    "dark with a wide spread and little fine detail"),
    "disco": (BLOG + "sony_a7_iv_79.arw", "pick 8: two children's legs and shoes on asphalt under coloured disco light at "
              "night (no skin shows); dark, saturated violet, strong detail"),
    "flower": (BLOG + "sony_a7_iv_33.arw", "pick 9: a yellow flower close up on a soft green ground"),
    "birches": (GALLERY + "Y-JG-SONY-A7-IV-1427.ARW", "pick 10: three birch trunks before a dull grey ground, portrait "
                "orientation; bright, narrow spread, the least fine detail of the twenty"),
    "dog-woods": (GALLERY + "Y-JG-SONY-A7-IV-1833.ARW", "pick 11: a dog on its hind legs in snowy woods, portrait "
                  "orientation; bright with a wide spread"),
    "chickadee": (GALLERY + "Y-JG-SONY-A7-IV-0217.ARW", "pick 12: a chickadee on a twig before a soft beige background"),
    "tower": (BLOG + "sony_a7_iv_05.arw", "pick 13: a glass tower over bare trees and a street under blue sky, portrait "
              "orientation; dark ground and bright sky, strong fine detail"),
    "concrete": (BLOG + "sony_a7_iv_07.arw", "pick 14: an empty concrete hall under strip lights, warm light"),
    "gulls": (GALLERY + "Y-JG-SONY-A7-IV-0674.ARW", "pick 15: two gulls on a wet beach at dusk; bright with strong coarse "
              "detail"),
    "wave": (GALLERY + "Y-JG-SONY-A7-IV-0614.ARW", "pick 16: a breaking wave close up, smooth water and spray"),
    "chandeliers": (BLOG + "sony_a7_iv_08.arw", "pick 17: crystal chandeliers in mirrors, bright points on dark; strong "
                    "detail at both scales"),
    "holly": (GALLERY + "Y-WB-Sigma60_600_BETA-DSC00505.ARW", "pick 18: a bird half hidden in holly leaves, shallow focus; "
              "wide spread, strong coarse detail"),
    "wave-shore": (GALLERY + "Y-JG-SONY-A7-IV-0405.ARW", "pick 19: a wave breaking before a wooded rocky shore at dusk"),
    "bird-branches": (GALLERY + "Y-WB-Sigma60_600_BETA-DSC00378.ARW", "pick 20: a small bird in bare branches before a soft "
                      "background, portrait orientation"),
}


def plan_q():
    tone = presence_charts.TONE_SIZE
    out = [Job("q-tone-four", Q_CHARTS / "q-tone-four.dng", "chart", singles(["clarity"], TONE_VALUES),
               "F1 request 1: four 0.05-stop gratings at period 64 at mean -4, -2, 0 and +1.5 stops in one frame on "
               "middle grey, Clarity at four values", "q-tone-four", tone, ("clarity",))]
    for ground, what in (("dark", "all dark (-6 stops)"), ("bright", "all bright (+2 stops)"), ("ramp", "a 12-stop ramp")):
        out.append(Job(f"q-tone-{ground}", Q_CHARTS / f"q-tone-{ground}.dng", "chart", singles(["clarity"], [100]),
                       f"F1 request 1: q-tone-four's 0-stop grating alone, in the same box, on a frame that is otherwise "
                       f"{what}, Clarity +100", f"q-tone-{ground}", tone, ("clarity",)))
    out.append(Job("q-edge", Q_CHARTS / "q-edge.dng", "chart", singles(["texture", "clarity"], [100]),
                   "F1 request 2: 0.25-stop gratings at 8 and 32 pixels across a 3-stop bar at 0 stops, and the bar "
                   "alone, at Texture +100 and Clarity +100", "q-edge", presence_charts.EDGE_SIZE, ("texture", "clarity")))
    out.append(Job("q-combo", CHARTS / "p-combo.dng", "chart", singles(["texture", "clarity"], [100]) + (PAIR,),
                   "F1 request 3: p-combo at Texture +100, Clarity +100 and both (p-combo has them only at +50)",
                   "p-combo", chart_size("p-combo"), ("texture", "clarity"), TWINS["q-combo"]))
    out.append(Job("q-raw", PROBE_RAW, "probe raw", (("00_base", {}), PAIR),
                   "F1 request 3: the probe raw at Texture +100 with Clarity +100 (the first round-2 run; its singles are "
                   "q-raw-repeat's)", twin=TWINS["q-raw"]))
    out.append(Job("q-raw-repeat", PROBE_RAW, "probe raw",
                   (("00_base", {}), ("repeat", {})) + singles(["texture", "clarity"], [100])[1:],
                   "the probe raw's base twice in one run, against each other and against q-raw's base (does Lightroom "
                   "render the same input the same way within a run and between runs?), and Texture +100 and Clarity "
                   "+100 alone for q-raw's pair", controls=("texture", "clarity"), twin=TWINS["q-raw-repeat"]))
    out.append(Job("q-grating-0", CHARTS / "p-grating-0.dng", "chart", singles(["texture", "clarity"], [100]) + (PAIR,),
                   "F1 request 3: p-grating-0, whose 0.8-stop bands meet the knee, at Texture +100, Clarity +100 and both",
                   "p-grating-0", chart_size("p-grating-0"), ("texture", "clarity"), TWINS["q-grating-0"]))
    photo_items = singles(["clarity"], PHOTO_CLARITY) + singles(["texture"], PHOTO_TEXTURE)[1:]
    for key, (path, why) in PHOTOS_Q.items():
        out.append(Job(f"q-photo-{key}", CORPUS / path, "photo", photo_items, why, controls=("texture", "clarity")))
    return out


# MARK: Round 3

R_CHARTS = DATA / "r-charts"
# F2's request 2 as Lightroom's crop keys: each edge a fraction of the width or the height.
LEFT_THIRD = {"CropLeft": "0", "CropRight": "0.333333", "CropTop": "0", "CropBottom": "1"}
BOTTOM_HALF = {"CropLeft": "0", "CropRight": "1", "CropTop": "0.5", "CropBottom": "1"}
# The plug-in passes a value as a number or a string, never a boolean, and Lightroom's HasCrop is one. Each spelling
# is tried on its own job, so one Lightroom refuses cannot stop the others. All three took (Lightroom writes
# HasCrop="True" itself), so the crop jobs give the edges alone.
CROP_FLAGS = {"true": {"HasCrop": "true"}, "1": {"HasCrop": "1"}, "none": {}}
HOLDOUT = singles(["dehaze"], [-100, 50, 100]) + singles(["vibrance"], [-100, 50, 100])[1:] + \
          singles(["saturation"], [-100, 100])[1:]
# F3's requests 1 and 2: Exposure beside Saturation and beside Vibrance of both signs, with every single in the same job.
GRID_ITEMS = singles(["saturation"], [50]) + singles(["vibrance"], [100, -100])[1:] + \
             tuple(combo(("ex", e)) for e in (1, -1)) + \
             tuple(combo(("ex", e), c) for c in (("sat", 50), ("vib", 100), ("vib", -100)) for e in (1, -1))
TWINS_R = {"r-haze-neutral": "p-haze-neutral", "r-haze-two": "p-haze-two", "r-colour-grid": "p-colour-grid",
           "r-colour-grid-tif": "p-colour-grid-tif", "r-sky-standard": "p-photo-sky",
           **{f"r-photo-{key}": f"q-photo-{key}" for key in PHOTOS_Q},
           "r-end-haze-neutral": "r-haze-neutral", "r-end-photo-horizon": "r-photo-horizon",
           **{f"r-again-haze-{k}": f"r-haze-{k}" for k in ("neutral", "two", "white")},
           **{f"r-again-photo-{k}": f"r-photo-{k}" for k in ("horizon", "mirror-lights")}}
# Dehaze's renders of p-haze-neutral and p-haze-two came out a few codes off round 1's where the bases and the colour
# renders were identical (measured), so a fifth run renders them again: each value twice in one job, against the same
# renders of the session's second run. Two of them differed within one job, so a sixth run asks the same of two
# photographs, the hazy one and the darkest with the most detail.
AGAIN_VALUES = {"neutral": [-100, -50, 25, 50, 100], "two": [100], "white": [100], "horizon": [-100, 100],
                "mirror-lights": [-100, 100]}


def again(values):
    return (("00_base", {}),) + tuple((f"{prefix}dehaze_{v:+d}", {"Dehaze": f"{v:g}"}) for v in values
                                      for prefix in ("", "again_"))


def cropped(items, crop):
    return tuple((label, {**crop, **settings}) for label, settings in items)


def plan_r():
    haze = presence_charts.HAZE_SIZE
    neutral, two = CHARTS / "p-haze-neutral.dng", CHARTS / "p-haze-two.dng"
    out = [Job(f"r-crop-flag-{flag}", neutral, "chart", cropped((("00_base", {}),), {**LEFT_THIRD, **spelling}),
               f"F2 request 2, the plug-in's crop: p-haze-neutral cropped to its left third with HasCrop spelt "
               f"{flag if spelling else 'not at all'}; the export's size shows whether the crop took", "p-haze-neutral",
               (1600, 3200)) for flag, spelling in CROP_FLAGS.items()]
    out.append(Job("r-haze-neutral", neutral, "chart", singles(["dehaze"], RAW_VALUES)[:1] + (("repeat", {}),) +
                   singles(["dehaze"], RAW_VALUES)[1:],
                   "F2 request 1: p-haze-neutral at Dehaze's ten values (-10, +10, -75 and +75 asked; the knots beside "
                   "them so the curve is from one session), and its base twice", "p-haze-neutral", haze, ("dehaze",),
                   TWINS_R["r-haze-neutral"]))
    out.append(Job("r-haze-neutral-crop", neutral, "chart", cropped(singles(["dehaze"], [100]), LEFT_THIRD),
                   "F2 request 2: p-haze-neutral cropped to its left third (x 0 to 1600), Dehaze +100; its uncropped "
                   "render is r-haze-neutral's", "p-haze-neutral", (1600, 3200), ("dehaze",)))
    out.append(Job("r-haze-two", two, "chart", singles(["dehaze"], [100]),
                   "F2 request 2: p-haze-two uncropped at Dehaze +100, for its crop in the same session", "p-haze-two",
                   haze, ("dehaze",), TWINS_R["r-haze-two"]))
    out.append(Job("r-haze-two-crop", two, "chart", cropped(singles(["dehaze"], [100]), BOTTOM_HALF),
                   "F2 request 2: p-haze-two cropped to its bottom half (warm haze only), Dehaze +100", "p-haze-two",
                   (4800, 1600), ("dehaze",)))
    out.append(Job("r-sky-standard", CORPUS / PHOTOS["sky"][0], "photo", singles(["dehaze"], [50, 100]),
                   "F2 request 3: p-photo-sky's raw at Dehaze +50 and +100 under Adobe Standard, with no look",
                   controls=("dehaze",), twin=TWINS_R["r-sky-standard"]))
    out.append(Job("r-sky-matrix", R_CHARTS / "r-sky-matrix.dng", "chart", singles(["dehaze"], [50, 100]),
                   "F2 request 3: the same photograph through a matrix alone (no hue map, no look table), as a DNG of "
                   "the spike's decode at the ARW's level, at Dehaze +50 and +100", "r-sky-matrix", RAW_SIZE, ("dehaze",)))
    out.append(Job("r-haze-white", R_CHARTS / "r-haze-white.dng", "chart", singles(["dehaze"], [50, 100]),
                   "F2 request 4: p-haze-neutral with a 64 x 64 patch of 0.95 in its haziest strip, Dehaze +50 and +100",
                   "r-haze-white", haze, ("dehaze",)))
    out.append(Job("r-colour-grid", CHARTS / "p-colour-grid.dng", "chart", GRID_ITEMS,
                   "F3 requests 1 and 2: the colour grid at Exposure +1 and -1, each alone, beside Saturation +50 and "
                   "beside Vibrance +100 and -100, and those three alone", "p-colour-grid", chart_size("p-colour-grid"),
                   ("vibrance", "saturation"), TWINS_R["r-colour-grid"]))
    out.append(Job("r-colour-grid-tif", CHARTS / "p-colour-grid.tif", "chart", singles(["vibrance"], RAW_VALUES),
                   "F3 request 3: the TIFF grid at Vibrance's ten values (10, 75, -10 and -75 asked; the knots beside "
                   "them so the law is from one session)", "p-colour-grid", chart_size("p-colour-grid"), ("vibrance",),
                   TWINS_R["r-colour-grid-tif"]))
    for key, (path, why) in PHOTOS_Q.items():
        out.append(Job(f"r-photo-{key}", CORPUS / path, "photo", HOLDOUT,
                       f"held out, round 2's q-photo-{key}: {why}", controls=("dehaze", "vibrance", "saturation"),
                       twin=TWINS_R[f"r-photo-{key}"]))
    for key, source in (("neutral", neutral), ("two", two), ("white", R_CHARTS / "r-haze-white.dng")):
        layout = "r-haze-white" if key == "white" else f"p-haze-{key}"
        out.append(Job(f"r-again-haze-{key}", source, "chart", again(AGAIN_VALUES[key]),
                       f"whether Dehaze repeats: {layout} at Dehaze {', '.join(f'{v:+d}' for v in AGAIN_VALUES[key])}, "
                       f"each twice in this job, against r-haze-{key}'s renders of the session's second run", layout, haze,
                       ("dehaze",), TWINS_R[f"r-again-haze-{key}"]))
    for key in ("horizon", "mirror-lights"):
        out.append(Job(f"r-again-photo-{key}", CORPUS / PHOTOS_Q[key][0], "photo", again(AGAIN_VALUES[key]),
                       f"whether Dehaze repeats on a photograph: q-photo-{key}'s frame at Dehaze -100 and +100, each "
                       f"twice in this job, against r-photo-{key}'s renders of the session's third run",
                       twin=TWINS_R[f"r-again-photo-{key}"]))
    out.append(Job("r-end-haze-neutral", neutral, "chart", (("00_base", {}),),
                   "the session's fourth run: p-haze-neutral's base again, against r-haze-neutral's from its second",
                   "p-haze-neutral", haze, twin=TWINS_R["r-end-haze-neutral"]))
    out.append(Job("r-end-photo-horizon", CORPUS / PHOTOS_Q["horizon"][0], "photo", (("00_base", {}),),
                   "the session's fourth run: q-photo-horizon's frame again, against r-photo-horizon's from its third",
                   twin=TWINS_R["r-end-photo-horizon"]))
    return out


PLANS = {1: plan, 2: plan_q, 3: plan_r}


def by_name():
    return {job.name: job for make in PLANS.values() for job in make()}


def write(names):
    table = by_name()
    names = [name for pattern in names for name in (fnmatch.filter(table, pattern) or [pattern])]
    for name in names:
        job = table[name]
        folder = jobs.jobs_dir()
        if any((folder / f"{name}{suffix}").exists() for suffix in (".job", ".processed", ".done")):
            print(f"{name}: already written or run, skipped")
            continue
        if not job.source.exists():
            raise SystemExit(f"{name}: {job.source} is missing")
        inputs = DATA / "inputs" / name
        items = []
        for label, settings in job.items:
            target = jobs.clone(job.source, inputs / f"{job.stem(label)}{job.source.suffix.lower()}")
            items.append((target, jobs.settings_for(target, settings)))
        jobs.write(name, DATA / f"exports-{name}", items)


def listing(number):
    total = 0
    for job in PLANS[number]():
        total += job.bytes()
        print(f"{job.name:22s} {len(job.items):3d} renders {job.bytes() / 1e9:6.2f} GB  {job.source.name}")
    print(f"{sum(len(j.items) for j in PLANS[number]())} renders, {total / 1e9:.1f} GB of exports")


# MARK: Choosing round 2's photographs

# The quick decode the frames are measured on: quarter size, no lens correction and no noise reduction, as Lightroom's
# renders here have none. Without `--nr 0 --luma-nr 0` the spike's noise reduction, keyed to ISO, hides most of the
# noise: on the still life's ISO series `fine` then reads 0.128 at ISO 50 and 0.167 at 204800, against 0.300 without.
DECODE = ("--scale", 0.25, "--no-lens", "--nr", 0, "--luma-nr", 0)
FLOOR = 2.0 ** -12  # of middle grey: the darkest level a measure takes, so noise around black does not dominate it
# Frames of one scene (by eye from a contact sheet of the quick decodes); every other frame is a scene of its own.
SCENES = {
    "lupines in sea fog": ["Y-JG-A7-IV-FE-24-105-4830", "Y-JG-A7-IV-FE-24-105-4834", "Y-JG-A7-IV-FE-24-105-4854"],
    "chickadee": ["Y-JG-SONY-A7-IV-0216", "Y-JG-SONY-A7-IV-0217"],
    "dog on grey snow": ["Y-JG-SONY-A7-IV-0255", "Y-JG-SONY-A7-IV-0273", "Y-JG-SONY-A7-IV-0282"],
    "breaking wave": ["Y-JG-SONY-A7-IV-0528", "Y-JG-SONY-A7-IV-0614"],
    "gull on the beach": ["Y-JG-SONY-A7-IV-0674", "Y-JG-SONY-A7-IV-0717", "Y-JG-SONY-A7-IV-0748", "Y-JG-SONY-A7-IV-0809",
                          "Y-JG-SONY-A7-IV-1090", "Y-JG-SONY-A7-IV-1174"],
    "dog in snowy woods": ["Y-JG-SONY-A7-IV-1795", "Y-JG-SONY-A7-IV-1823", "Y-JG-SONY-A7-IV-1833"],
    "small bird in bare branches": ["Y-WB-Sigma60_600_BETA-DSC00214", "Y-WB-Sigma60_600_BETA-DSC00378",
                                    "Y-WB-Sigma60_600_BETA-DSC00531"],
    "fog in bare woods": ["Y-WB-Sigma60_600_BETA-DSC00424", "Y-WB-Sigma60_600_BETA-DSC00426"],
    "holly": ["Y-WB-Sigma60_600_BETA-DSC00505", "Y-WB-Sigma60_600_BETA-DSC00513"],
    "still life ISO series": [f"A7M4hSLI{iso:06d}NR0" for iso in (50, 100, 200, 400, 800, 1600, 3200, 6400, 12800,
                                                                   25600, 51200, 102400, 204800)],
    "turbine hall": ["sony_a7_iv_13", "sony_a7_iv_14", "sony_a7_iv_16"],
    "yellow flowers": ["sony_a7_iv_33", "sony_a7_iv_34"],
    "the probe raw's tree and wall": [f"ILCE-7M4_DSC0667{k}_FullFrame-{mode}" for k, mode in
                                      ((3, "Raw-Uncompressed"), (4, "LossLess-Compressed-Large"),
                                       (5, "LossLess-Compressed-Medium"), (6, "LossLess-Compressed-Small"),
                                       (7, "Raw-Compressed"))],
}
SCENE_OF = {stem: scene for scene, stems in SCENES.items() for stem in stems}
# Taken whatever their measures, for what they show: the brief asks for a portrait (the corpus has none) and for distant
# atmospheric haze, which only this frame shows, on a strip of islands and far shore at the horizon.
FORCED = ["Y-JG-A7-IV-FE-24-105-4901"]
MEASURES = ["median", "spread", "fine", "coarse"]
# Median and spread count once each, and detail once, shared between its fine and coarse parts.
WEIGHTS = np.array([1.0, 1.0, 0.5 ** 0.5, 0.5 ** 0.5])


def scene_measures(scene):
    """Measures of a scene-linear Rec. 2020 array (middle grey 0.18) on its luminance, in log2 stops over middle grey:
    the median, the 10th and 90th percentiles and the spread between them; `fine`, the rms of the log luminance less
    its 3-pixel box mean; and `coarse`, the rms of its 5-pixel box mean less its 65-pixel box mean. On a quarter-size
    decode of a 7008-pixel frame the fine band is periods of about 4 to 12 full-size pixels (Texture's) and the coarse
    band about 20 to 260 (Clarity's)."""
    y = np.asarray(scene, np.float64) @ presence_charts.REC2020_Y
    log = np.log2(np.maximum(y / presence_charts.MID, FLOOR))
    p10, median, p90 = np.percentile(log, [10, 50, 90])
    fine = np.sqrt(np.mean((log - presence_stats.box(log, 1)) ** 2))
    coarse = np.sqrt(np.mean((presence_stats.box(log, 2) - presence_stats.box(log, 32)) ** 2))
    return {"median": round(float(median), 3), "spread": round(float(p90 - p10), 3), "fine": round(float(fine), 4),
            "coarse": round(float(coarse), 4), "p10": round(float(p10), 3), "p90": round(float(p90), 3),
            "size": [int(scene.shape[1]), int(scene.shape[0])]}


def frame_measures(raw):
    return scene_measures(scene_io.scene_of(raw, STOCK, *DECODE, binary=SPIKE))


def choose(rows, seeds, n, forced=()):
    """Farthest-point choice: the rows whose path stem is in `forced` first, then `rows` (dicts of MEASURES, a `scene`
    and a `path`) one at a time, each the row farthest from every seed and every row already taken, in the measures
    scaled by their spread over all rows and weighted by WEIGHTS. A scene that is taken, or that a seed holds, gives
    no other row. A forced row's `distance` is None."""
    everything = rows + seeds
    values = np.array([[r[m] for m in MEASURES] for r in everything], np.float64)
    scale = values.std(axis=0)
    points = values / np.where(scale > 0, scale, 1) * WEIGHTS
    taken_points = [points[len(rows) + k] for k in range(len(seeds))]
    taken_scenes = {s["scene"] for s in seeds}
    order = []

    def take(k, distance):
        order.append({**rows[k], "distance": distance})
        taken_points.append(points[k])
        taken_scenes.add(rows[k]["scene"])

    for k, row in enumerate(rows):
        if Path(row["path"]).stem in forced and len(order) < n:
            take(k, None)
    while len(order) < n:
        best, distance = None, -1.0
        for k, row in enumerate(rows):
            if row["scene"] in taken_scenes:
                continue
            d = min((float(np.linalg.norm(points[k] - p)) for p in taken_points), default=np.inf)
            if d > distance:
                best, distance = k, d
        if best is None:
            break
        take(best, round(distance, 3))
    return order


def candidates():
    """Every raw of the corpus and the samples, each a dict of its path and its scene, split into the pool and the
    seeds (round 1's photographs and the probe raw's source)."""
    used = {(CORPUS / path).resolve() for path, _ in PHOTOS.values()} | {PROBE_SOURCE.resolve()}
    files = sorted(p for d in CORPUS.iterdir() if d.is_dir() for p in d.iterdir() if p.suffix.lower() == ".arw")
    files += sorted(SAMPLES.glob("*.ARW"))
    pool, seeds = [], []
    for path in files:
        entry = {"path": str(path), "scene": SCENE_OF.get(path.stem, path.stem)}
        (seeds if path.resolve() in used else pool).append(entry)
    return pool, seeds


def frames(out):
    out.mkdir(parents=True, exist_ok=True)
    pool, seeds = candidates()
    for entry in pool + seeds:
        entry.update(frame_measures(entry["path"]))
        print(f"  {Path(entry['path']).name}: {', '.join(f'{m} {entry[m]}' for m in MEASURES)}", flush=True)
    order = choose(pool, seeds, len(pool), FORCED)
    result = {"made": time.strftime("%Y-%m-%d %H:%M:%S"), "spike": str(SPIKE), "decode": [str(a) for a in DECODE],
              "stock": str(STOCK), "weights": dict(zip(MEASURES, WEIGHTS.round(4).tolist())), "seeds": seeds,
              "order": order, "left": [r for r in pool if r["path"] not in {o["path"] for o in order}]}
    (out / "frame-candidates.json").write_text(json.dumps(result, indent=1))
    lines = ["# Round 2: candidate photographs, in the order the farthest-point choice takes them", "",
             f"Made by `presence_plan.py frames` on {result['made']}. Measures on `argent-spike {' '.join(result['decode'])}` "
             "(the scene the film render receives, linear Rec. 2020, middle grey 0.18), in stops over middle grey: "
             "median, spread from the 10th to the 90th percentile, `fine` and `coarse` log detail (presence_plan."
             "scene_measures). Each row is the frame farthest from round 1's photographs, the probe raw and the rows "
             "above it, in the measures scaled by their spread and weighted median 1, spread 1, fine and coarse 0.71 "
             "each, one frame a scene, after the frames taken on purpose (FORCED, distance blank). `distance` is that "
             "distance when it was taken. Round 2 renders the first 20.", "",
             "| # | Frame | Scene | Median | Spread | Fine | Coarse | Distance |", "| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |"]
    for k, r in enumerate(order, 1):
        distance = "" if r["distance"] is None else f"{r['distance']:.2f}"
        lines.append(f"| {k} | `{Path(r['path']).name}` | {r['scene']} | {r['median']:+.2f} | {r['spread']:.2f} | "
                     f"{r['fine']:.3f} | {r['coarse']:.3f} | {distance} |")
    lines += ["", "Seeds (round 1's photographs and the probe raw's scene):", "",
              "| Frame | Median | Spread | Fine | Coarse |", "| --- | ---: | ---: | ---: | ---: |"]
    lines += [f"| `{Path(r['path']).name}` | {r['median']:+.2f} | {r['spread']:.2f} | {r['fine']:.3f} | {r['coarse']:.3f} |"
              for r in seeds]
    lines += ["", "Not taken (a seed's scene or a taken frame's):", ""]
    lines += [f"- `{Path(r['path']).name}` ({r['scene']}): median {r['median']:+.2f}, spread {r['spread']:.2f}, "
              f"fine {r['fine']:.3f}, coarse {r['coarse']:.3f}" for r in result["left"]] or ["None."]
    (out / "frame-candidates.md").write_text("\n".join(lines) + "\n")


# MARK: The manifest

# The statistic each control should move (presence_stats), and the way it should go at a positive value.
EXPECT = {name: (presence_stats.STATISTIC[name], -1 if name == "dehaze" else 1) for name in jobs.PRESENCE}


def requested(job):
    """What the job file asked for, item by item, as the plug-in read it."""
    folder = jobs.jobs_dir()
    path = next((folder / f"{job.name}{s}" for s in (".processed", ".job") if (folder / f"{job.name}{s}").exists()), None)
    if path is None:
        return None
    asked = {}
    for line in path.read_text().splitlines():
        if line.startswith("ITEM\t"):
            parts = line.split("\t")
            asked[Path(parts[1]).stem] = (parts[1], dict(p.split("=", 1) for p in parts[2].split(";") if p) if len(parts) > 2 else {})
    return asked


def number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return text


def same(asked, applied):
    """A setting asked for against the one the export says it rendered with: numbers to 1e-4 (Lightroom writes a crop
    edge to six places), and a flag by its truth (HasCrop asked as "true" or 1 comes back "True")."""
    a, b = number(asked), number(applied)
    if isinstance(a, float) and isinstance(b, float):
        return abs(a - b) <= 1e-4
    if str(applied).lower() in ("true", "false"):
        return (str(asked).lower() == "true" or a == 1.0) == (str(applied).lower() == "true")
    return str(asked).lower() == str(applied).lower()


APPLIED = ("ProcessVersion", "CameraProfile", "Texture", "Clarity2012", "Dehaze", "Vibrance", "Saturation", "Exposure2012",
           "Contrast2012", "Highlights2012", "Shadows2012", "Sharpness", "LuminanceSmoothing", "ColorNoiseReduction",
           "LensProfileEnable", "ToneCurveName2012", "HasCrop", "CropLeft", "CropRight", "CropTop", "CropBottom",
           "CropAngle")


def read_export(job, label, asked, base=None):
    """One export's entry for the manifest, and its CIELAB blocks (None when it could not be read)."""
    path = job.export(label)
    entry = {"path": str(path), "job": job.name, "label": label, "source": str(job.source), "sourceKind": job.kind,
             "layout": f"chart-layouts/{job.layout}.json" if job.layout else None}
    stem = job.stem(label)
    if asked is None or stem not in asked:
        entry["problem"] = "not in the job file"
        return entry, None
    entry["input"], entry["settings"] = asked[stem]
    if not path.exists():
        entry["problem"] = "missing"
        return entry, None
    values, look = presence_stats.settings(path)
    entry["look"] = look
    entry["applied"] = {k: values.get(k) for k in APPLIED}
    entry["bytes"] = path.stat().st_size
    stats, lab = presence_stats.measure(path, base)
    entry["size"] = stats.pop("size")
    entry["pixels"] = stats.pop("pixels")
    entry["stats"] = {k: round(v, 5) for k, v in stats.items()}
    problems = []
    for key, value in entry["settings"].items():
        if key == "CameraProfile":
            continue
        if not same(value, values.get(key)):
            problems.append(f"{key} asked {value}, applied {values.get(key)}")
    profile = entry["settings"].get("CameraProfile", "Adobe Standard")
    if job.source.suffix.lower() not in jobs.NOT_RAW and (look is not None or values.get("CameraProfile") != profile):
        problems.append(f"profile {values.get('CameraProfile')} with look {look}")
    if sorted(entry["size"]) != sorted(job.size):
        problems.append(f"size {entry['size'][0]} x {entry['size'][1]}, expected {job.size[0]} x {job.size[1]}")
    if problems:
        entry["problem"] = "; ".join(problems)
    return entry, lab


def sanity(job, entries):
    """For each control on this source: its statistic's change from the base at every value, and a verdict: each value
    moves it the way the control implies, and each value moves it more than the smaller ones of its sign. Where a sign
    has one value, only its direction is checked, and the verdict says so."""
    base = entries.get("00_base")
    rows = []
    if not base or "stats" not in base:
        return rows
    for control in job.controls:
        statistic, sign = EXPECT[control]
        if job.layout == "p-flat-grey":
            sign = None  # a flat field has no haze to remove: only how far it moves is checked
        changes = {}
        for label, e in entries.items():
            if label.startswith(control + "_") and "stats" in e:
                changes[int(label.split("_")[1])] = round(e["stats"][statistic] - base["stats"][statistic], 5)
        verdicts, alone = [], []
        for side in (1, -1):
            values = sorted((v for v in changes if v * side > 0), key=abs)
            if sign:
                verdicts += [f"{v:+d} moves {statistic} the wrong way" for v in values if changes[v] * sign * side <= 0]
            verdicts += [f"{large:+d} does not move {statistic} more than {small:+d}"
                         for small, large in zip(values, values[1:]) if not abs(changes[large]) > abs(changes[small]) > 0]
            if len(values) == 1:
                alone.append(values[0])
        verdict = "check: " + "; ".join(verdicts) if verdicts else "ok"
        if alone and not verdicts:
            verdict += f" (direction only at {', '.join(f'{v:+d}' for v in alone)}: one value of that sign)"
        rows.append({"job": job.name, "source": str(job.source), "control": control, "statistic": statistic,
                     "base": base["stats"][statistic], "change": dict(sorted(changes.items())), "verdict": verdict})
    return rows


def pairs(job, entries):
    """Each render that sets a Presence control beside another setting: every Presence control's statistic against the
    render that differs from it by its Presence controls alone (the base, or the same Exposure alone), which it should
    move the way the control moves it alone."""
    base = entries.get("00_base")
    if not base or "stats" not in base:
        return []
    control_of = {jobs.KEYS[c]: c for c in jobs.PRESENCE}
    rows = []
    for label, e in entries.items():
        settings = e.get("settings", {})
        controls = [(control_of[k], float(v)) for k, v in settings.items() if k in control_of]
        rest = {k: v for k, v in settings.items() if k not in control_of}
        if not controls or (len(controls) < 2 and rest == base.get("settings")) or "stats" not in e:
            continue
        against = next((k for k, r in entries.items() if r.get("settings") == rest and "stats" in r), None)
        if against is None:
            rows.append({"job": job.name, "label": label, "against": None, "change": {},
                         "verdict": "check: no render without its Presence controls"})
            continue
        change, wrong = {}, []
        for control, value in controls:
            statistic, sign = EXPECT[control]
            d = round(e["stats"][statistic] - entries[against]["stats"][statistic], 5)
            change[f"{control} {value:+g}: {statistic}"] = d
            if d * sign * np.sign(value) <= 0:
                wrong.append(f"{statistic} moves the wrong way for {control}")
        rows.append({"job": job.name, "label": label, "against": against, "change": change,
                     "verdict": "check: " + "; ".join(wrong) if wrong else "ok"})
    return rows


def difference(a, b, rows=512):
    """How two exports' pixels differ in 16-bit codes: whether they are identical, the fraction of codes that differ,
    the largest difference and the mean. None when either is missing or their sizes differ."""
    if not (a.exists() and b.exists()):
        return None
    x, y = probe.read_tiff(a)[0], probe.read_tiff(b)[0]
    if x.shape != y.shape:
        return None
    count, largest, total = 0, 0, 0.0
    for k in range(0, x.shape[0], rows):
        d = np.abs(np.rint(x[k:k + rows] * 65535) - np.rint(y[k:k + rows] * 65535))
        count += int(np.count_nonzero(d))
        largest = max(largest, int(d.max()))
        total += float(d.sum())
    return {"identical": count == 0, "codesDiffer": round(count / x.size, 5), "max": largest,
            "mean": round(total / x.size, 4)}


def frame_row(job, base_stats, decode=True):
    """A photograph's measures on the quick decode (scene_measures), and Lightroom's statistics of its base export."""
    row = {"job": job.name, "source": str(job.source), "scene": SCENE_OF.get(job.source.stem, job.source.stem),
           "why": job.why, "twin": job.twin}
    if decode:
        row["decode"] = frame_measures(job.source)
    if base_stats:
        row["lightroomBase"] = {k: round(base_stats[k], 5) for k in ("fine", "local", "spread", "lightness", "chroma",
                                                                     "dark")}
    return row


IDENTICAL = {"identical": True, "codesDiffer": 0.0, "max": 0, "mean": 0.0}


def twin_check(job, twin, entries, same_round):
    """Every render of `job` against the render of `twin` (the same source in another job) that asked for the same
    settings, code by code; the base's comparison also at the top level."""
    theirs = {}
    for label, settings in twin.items:
        theirs.setdefault(tuple(sorted(settings.items())), label)
    renders = {}
    for label, settings in job.items:
        match = theirs.get(tuple(sorted(settings.items())))
        if match is not None and entries[label].get("pixels"):
            renders[label] = {"of": match, **(difference(job.export(label), twin.export(match)) or {"identical": False})}
    base = renders.get("00_base", {"identical": False})
    return {"job": twin.name, "base": str(twin.export("00_base")), "sameRound": same_round,
            **{k: base[k] for k in IDENTICAL if k in base}, "renders": renders}


def flag(entry, problem):
    entry["problem"] = f"{entry['problem']}; {problem}" if entry.get("problem") else problem


def manifest(out, number=1):
    """Round `number`'s manifest in `out`, and the layout of every chart its jobs render in out/chart-layouts/."""
    out.mkdir(parents=True, exist_ok=True)
    result = {"made": time.strftime("%Y-%m-%d %H:%M:%S"), "round": number, "data": str(DATA), "jobs": [], "exports": [],
              "sanity": [], "pairs": [], "frames": [], "wrong": []}
    named = by_name()
    this_round = {job.name for job in PLANS[number]()}
    for job in PLANS[number]():
        asked = requested(job)
        entries, base = {}, None
        for label, _ in job.items:
            entries[label], lab = read_export(job, label, asked, base)
            if label == "00_base":
                base = lab
            print(f"  {job.stem(label)}: {entries[label].get('problem', 'ok')}", flush=True)
        base_pixels = entries["00_base"].get("pixels")
        first, repeats = {}, {}
        for label, e in entries.items():
            if not e.get("pixels"):
                continue
            asked_for = tuple(sorted(e["settings"].items()))
            if asked_for not in first:
                first[asked_for] = label
                if label != "00_base" and e["pixels"] == base_pixels:
                    flag(e, "pixels identical to the base")
                continue
            earlier = first[asked_for]
            repeats[label] = {"of": earlier, **(IDENTICAL if e["pixels"] == entries[earlier]["pixels"] else
                                                difference(job.export(label), job.export(earlier)))}
            if earlier == "00_base" and not repeats[label]["identical"]:
                flag(e, "asks for the base's settings but its pixels differ from the base's")
        summary = {"name": job.name, "source": str(job.source), "kind": job.kind, "why": job.why,
                   "layout": f"chart-layouts/{job.layout}.json" if job.layout else None,
                   "exports": str(DATA / f"exports-{job.name}"), "renders": len(job.items), "ran": asked is not None}
        if repeats:
            summary["repeats"] = repeats
        if job.twin:
            summary["twin"] = twin_check(job, named[job.twin], entries, job.twin in this_round)
            if summary["twin"]["sameRound"] and not summary["twin"]["identical"]:
                flag(entries["00_base"], f"base not identical to {job.twin}'s, rendered in the same session")
        if job.layout:
            layout = job.source.parent / f"{job.layout}-layout.json"
            (out / "chart-layouts").mkdir(exist_ok=True)
            (out / "chart-layouts" / f"{job.layout}.json").write_text(layout.read_text())
        result["jobs"].append(summary)
        result["exports"].extend(entries.values())
        result["sanity"].extend(sanity(job, entries))
        result["pairs"].extend(pairs(job, entries))
        # Round 3 renders round 2's frames again: their quick-decode measures are in round 2's manifest.
        if job.kind == "photo" and job.controls:
            result["frames"].append(frame_row(job, entries["00_base"].get("stats"), decode=number < 3))
    if number == 2:
        # The earlier rounds' photographs, measured the same way, so a frame statistic can be fitted on all of them.
        earlier = [job for k in range(1, number) for job in PLANS[k]() if job.kind == "photo"]
        result["earlierFrames"] = [frame_row(job, presence_stats.measure(job.export("00_base"))[0]
                                             if job.export("00_base").exists() else None) for job in earlier]
    result["wrong"] = [{"path": e["path"], "problem": e["problem"]} for e in result["exports"] if e.get("problem")]
    result["totals"] = {"exports": sum(1 for e in result["exports"] if "bytes" in e),
                        "bytes": sum(e.get("bytes", 0) for e in result["exports"])}
    (out / "manifest.json").write_text(json.dumps(result, indent=1))
    (out / "manifest.md").write_text(markdown(result))
    print(f"{result['totals']['exports']} exports, {result['totals']['bytes'] / 1e9:.2f} GB, {len(result['wrong'])} wrong")


# What a fit agent should know before reading a pixel, by round. Each line says how it is known.
NOTES = {1: [
    "**Base.** Every raw render (the probe raw and the photographs) is Adobe Standard with no look, process version 15.4, "
    "white balance As Shot, sharpening, noise reduction, lens corrections, vignette and grain off, and a linear point curve "
    "(read back from each export's XMP). The probe raw's base is bit-identical to the 2026-10-29 probe's "
    "`exports/raw_00_base.tif`, and so are its Exposure +1 and Highlights -100 singles (measured, 0 codes differ), so the "
    "Light controls' 37 old renders combine with these.",
    "**Format.** Exports are uncompressed 16-bit ProPhoto RGB TIFFs whose ICC is a pure gamma of 461/256; "
    "`presence_stats.linear(path)` returns linear ProPhoto (D50). `probe.read_tiff` reads the input charts too.",
    "**Charts are raws.** The DNG charts take Lightroom's raw path: the Embedded profile, no look, and Lightroom's raw tone "
    "curve (a neutral at scene L* 40 renders near L* 54; measured on p-colour-grid's neutrals). Compare a render with its "
    "own base, not with the chart's values. Exports have the chart's size and its pixels: a grating's phase and a bar's "
    "edges sit exactly where the layout says (shift 0 pixels, measured on p-grating-0 and p-steps).",
    "**The TIFF grid is a finished picture.** p-colour-grid-tif's base renders the colours the TIFF encodes (median "
    "Delta E 0.03, measured), so it shows Vibrance and Saturation on output colours with no tone curve; p-colour-grid (DNG) "
    "shows them after the raw path.",
    "**Rebuild the inputs exactly.** `presence_charts.CHARTS[name]()` rebuilds any chart bit for bit (`.img` is linear "
    "Rec. 2020, or sRGB for p-locality). Simulating a candidate on the chart itself is safer than reading a gain "
    "analytically: the grating bands are 512 pixels tall (256 in the half twin), so a filter wider than about 250 pixels "
    "mixes neighbouring bands, which share the period and the phase but not the amplitude.",
    "**Clipped blacks.** On p-grating-m4 (-4 stops), Texture +50 and +100 drive the troughs of the 0.8-stop gratings at "
    "periods 2 to 5.7 pixels to exact black (113,000 and 172,000 zero pixels in the frame, against none at the base; "
    "measured). The log statistic `fine` jumps there for that reason. Leave clipped pixels out of any fit in log units.",
    "**Dehaze statistic.** Dehaze's sanity number is the dark channel (mean L* of min(R, G, B)), which it moves down at + "
    "and up at - on every source but one. The spread of L* was tried first and fails as a direction: on the haze-free "
    "p-steps it falls at both +100 and -100 (measured). On p-flat-grey Dehaze changes almost nothing (at most 0.004 L* of "
    "dark channel, measured): Dehaze needs structure to act on.",
    "**Frame adaptation.** Lightroom's Light controls adapt to the frame's content (docs/research/lightroom-sliders.md, "
    "section 4). Each grating chart holds one mean level, so a gain that changes with the mean may be tone dependence or "
    "frame adaptation (not separated here; guess that the Presence controls adapt too).",
    "**Photographs.** The corpus has no portrait: p-photo-skin is a red squirrel whose fur is in skin hues. Its hazy frame "
    "is sea fog, not distant atmospheric haze. p-photo-foliage is portrait orientation: its exports are 4672 x 7008.",
    "**Clarity and Texture overlap.** On the probe raw, Clarity +100 raises the 5-pixel band more than Texture +100 does "
    "(+66 % against +30 %, smoke test), so one band alone does not tell them apart; the gratings do.",
], 2: [
    "**Base.** As round 1's: every raw render is Adobe Standard with no look, process version 15.4, the probe's neutral "
    "sidecar (byte-identical to round 1's), white balance As Shot, sharpening, noise reduction, lens corrections, vignette "
    "and grain off, a linear point curve; DNG charts take the Embedded profile and Lightroom's raw tone curve. Read back "
    "from each export's XMP (`applied`). Exports are uncompressed 16-bit ProPhoto TIFFs, pure gamma 461/256, at the "
    "source's size; portrait frames are 4672 x 7008.",
    "**Lightroom's render moved a little since round 1; compare each render with its own job's base.** The probe raw's "
    "base, same raw and sidecar, came out different from p-raw's of 08:54 (12.7 % of codes differ, at most 53 of 65535, "
    "mean 0.70; mostly in the darks: a mean of 23 codes on the 2.5 % of pixels whose brightest channel is encoded at 2 to "
    "10 % of full scale, about 0.001 to 0.016 linear; mean Delta E 0.0036; the XMPs "
    "differ only in the file name; measured). Within this session Lightroom was deterministic: q-raw's base (11:18) and "
    "q-raw-repeat's base and repeat are bit-identical. The sliders' effects barely moved: Texture +100 less its base "
    "differs from round 1's by 0.80 codes on average against an effect of 1229, Clarity +100 by 1.30 against 3367 "
    "(measured). The charts moved too: q-combo's base against p-combo's, 15.0 % of codes, at most 41, mean 1.86; "
    "q-grating-0's against p-grating-0's, 2.0 %, at most 1, mean 0.02 (measured). The cause is unknown (guess: Lightroom "
    "chose another render path, GPU or CPU). Every q- job has its own base; each job's line below says whether its base "
    "equals its twin's.",
    "**Order of Texture and Clarity (F1 request 3).** Each pair at +100 has its singles from this session: in q-combo and "
    "q-grating-0 in the same job, and for the probe raw in q-raw-repeat, whose base is bit-identical to q-raw's. "
    "q-grating-0 is p-grating-0 (0.05, 0.2 and 0.8-stop bands, periods 2 to 1024 px), added because the 0.8-stop bands "
    "meet the knee before either slider acts; p-combo's gratings are 0.2 stop.",
    "**Tone charts (F1 request 1).** q-tone-four holds the 0.05-stop, 64-pixel grating at -4, -2, 0 and +1.5 stops in "
    "1280 x 512 cells (boxes in the layout) on middle grey. q-tone-dark, -bright and -ramp hold its 0-stop cell, the same "
    "pixels in the same box (3200, 1280, 4480, 1792), on a field of -6 stops, +2 stops, or a 12-stop ramp across the width "
    "(beside the cell the ramp is 5.75 to 3.25 stops under white; middle grey is 2.47 under). The cell borders its "
    "surround directly, a 6-stop step on the dark frame: measure away from its edges. In the base renders the grating's "
    "log2 amplitude is 0.089, 0.078, 0.052 and 0.024 at -4, -2, 0 and +1.5 stops (chart 0.05; the raw tone curve's "
    "slope; measured): take each cell's gain against its own base.",
    "**Clarity moves the tone cells themselves (first look, measured by a sinusoid fit in each cell's middle, 128 "
    "pixels in from its edges; `scratch/check_tone.py`).** At +100 each cell's mean log2 luminance moves by -1.46, -2.84, "
    "-0.14 and -0.02 on q-tone-four (-4, -2, 0, +1.5 stops), and the 0-stop cell's by -0.03 alone on dark, -3.70 on bright "
    "and +0.19 on the ramp: a 1280 x 512 cell is within Clarity's coarse band, so its level in the render depends on its "
    "surround. The grating's log2 amplitude against its own base: q-tone-four +100 2.33, 2.17, 2.03, 1.29; +50 2.00, "
    "1.82, 1.50, 1.14; -50 1.00, 0.85, 0.58, 0.62; -100 1.00, 0.75, 0.29, 0.35. The 0-stop cell alone at +100: 1.34 on "
    "dark, 9.73 on bright (a clean sinusoid, 0.10 to 1.01 log2 peak to peak, nothing clipped, with the cell 3.70 stops "
    "lower) and 1.91 on the ramp. Round 1's single-level gratings gave G - 1 = 0.74, 0.99, 1.10, 1.45 at +100, rising "
    "with level; in one frame it falls (1.33, 1.17, 1.03, 0.29). These are not a fit.",
    "**q-tone-dark's sanity check fails on the statistic, not the render.** Its `local` falls at +100 (-0.028) because "
    "presence_stats' central crop is dominated by the 6-stop edge round the cell; the grating itself rises (1.34, above).",
    "**Edge chart (F1 request 2).** q-edge's three 1024-row bands are a 3-stop bar at 0 stops (low -1.5, high +1.5 "
    "between columns 2048 and 4096) carrying a 0.25-stop grating at 8 pixels, then at 32 pixels, then the bar alone, whose "
    "render is the edge's own halo to subtract. The grating runs across both edges, so the dead zone shows on the dark "
    "and bright sides.",
    "**Geometry, measured on the base renders.** Every grating of q-tone-four and q-edge sits at the layout's phase "
    "(shift 0.00 pixels by a sinusoid fit), and q-edge's steps fall between columns 2047 and 2048 and between 4095 and "
    "4096, as the layout says.",
    "**Clipping, measured.** Clarity +100 drives the darkest 400 columns of q-tone-ramp's ramp to exact black (1,228,800 "
    "pixels = 400 x 3072; none at its base), far from the grating. The other tone charts, q-edge and q-grating-0 have no "
    "pixel at 0 or 65535 in any render. q-combo and the probe raw clip at both ends at their base already, and more with "
    "the pair (counts in `scratch/check_charts.log`). Leave clipped pixels out of any fit in log units.",
    "**Photographs.** Twenty frames at Clarity -100, -50, +50, +100 and Texture -100, +100, none of round 1's and one a "
    "scene, chosen by `presence_plan.py frames` (frame-candidates.md): 4901 on purpose, then each the frame farthest from "
    "round 1's photographs and the frames before it in median, spread and detail of a quick decode. The corpus has no "
    "portrait: q-photo-disco shows children's legs and shoes, no skin. Distant atmospheric haze shows only in "
    "q-photo-horizon, on a thin strip of islands and far shore at the horizon (lighter than the near trees, -0.7 against "
    "-2.35 stops on the quick decode, measured; bluer, by eye); q-photo-fog-woods is near fog. The table below gives each "
    "frame's measures, and round 1's photographs measured the same way, so a frame statistic can be fitted on all thirty.",
    "**The quick decode is the spike's, not Lightroom's.** Its medians are on argent-spike's exposure scale (middle grey "
    "0.18 of its own decode, no noise reduction), so they rank frames but are not Lightroom's levels; Lightroom's own "
    "`fine` and `local` of each base are beside them. `fine` there is full-size and includes noise.",
], 3: [
    "**Base.** As the earlier rounds': raws carry the probe's neutral sidecar (Adobe Standard with no look, process "
    "version 15.4, white balance As Shot, sharpening, noise reduction, lens corrections, vignette and grain off, a linear "
    "point curve); DNG charts and the TIFF grid read back as Embedded. Read back from all 262 exports (`applied`), each at "
    "the size the plan expects (`size`); portrait frames are 4672 x 7008. Six runs in one session, 11:58 to 12:21.",
    "**Dehaze on the synthetic haze charts does not repeat; nothing else failed to.** The manifest compares every render "
    "with every other render of the same source and settings, in its job, in this session and in rounds 1 and 2 "
    "(`repeats`, `twin.renders`). All 34 base comparisons, all 9 Vibrance and Saturation ones and all 14 Dehaze ones on "
    "photographs are identical to the code (the sky's +50 and +100 against round 1, and r-again-photo-horizon and "
    "-mirror-lights at -100 and +100, twice in one job and against run 3). Dehaze on p-haze-neutral, p-haze-two and "
    "r-haze-white is not: of 28 comparisons 10 are identical and 18 differ, and the same settings twice in one job can "
    "differ. The renders fall on a few outcomes: two renders differ by a mean of 0.33 codes at -50, 0.56 at -100, 0.87 "
    "at +50 and 3.3 at +100 (at most 39) on p-haze-neutral, by 4.4 to 9.0 (at most 143) on p-haze-two at +100, and by 16.1 "
    "(at most 161) on r-haze-white at +100. The difference is a smooth field that grows toward the haziest, right side "
    "(64-pixel block means from -32 to +63 codes; scratch/scatter_shape.py), as if an estimate of the haze varied from "
    "render to render (guess). Round 1's p-haze-neutral at -100, -50 and +50 is identical to one of this session's "
    "renders, and its +25 and p-haze-two's +100 differ from each of this session's by no more than those differ among "
    "themselves (scratch/check_round1_outcomes.log): these charts' difference from round 1 is this scatter, not a "
    "drift. On them, read a difference under the scatter as no effect.",
    "**The bases agree with the earlier rounds.** Each r- base equals the same source's base in round 1 (p-haze-neutral, "
    "p-haze-two, p-colour-grid, p-colour-grid-tif, p-photo-sky) or in round 2 (all twenty q-photo- frames) to the code, "
    "and so do the grids' shared Vibrance and Saturation renders. Round 2's drift (the probe raw, p-combo and p-grating-0 "
    "against round 1) did not reach these sources, so the earlier rounds' renders of them combine with these (measured "
    "for the renders compared; the cause of round 2's drift is still unknown).",
    "**Crop (F2 request 2): it takes, and Lightroom does not estimate from the crop.** Lightroom's crop keys go through "
    "the plug-in as fractions (`CropLeft`, `CropRight`, `CropTop`, `CropBottom`). HasCrop spelt `true`, `1` or left out "
    "all gave a 1600 x 3200 export with HasCrop=\"True\" in its XMP (r-crop-flag-*), and each crop's base equals the "
    "uncropped base's left third or bottom half to the code (scratch/check_crop.py). At Dehaze +100, "
    "r-haze-neutral-crop equals r-haze-neutral's +100 on the same pixels to the code, and r-haze-two-crop differs from "
    "r-haze-two's +100 by a mean of 2.5 codes (at most 51), less than two uncropped +100 renders of p-haze-two differ "
    "from each other (4.4 to 9.0), where Dehaze itself moves those pixels by a mean of 7377 codes "
    "(scratch/first_look.py). So the haze is estimated on the uncropped frame (inferred from those numbers).",
    "**Sky (F2 request 3): no profile Lightroom ships for the a7 IV is free of a look table.** Read from the app bundle's "
    "DCPs (scratch/dcp_tags.py): Adobe Standard holds a hue and saturation map (90 x 30 x 1) and a look table "
    "(36 x 8 x 16); each of the nine Camera profiles a look table (90 x 16 x 16) and a tone curve; Adobe Neutral and the "
    "other Adobe Raw profiles are Looks over Adobe Standard with a table of their own (Settings/Adobe/Profiles/Adobe "
    "Raw/*.xmp). So r-sky-matrix is the same photograph as a LinearRaw DNG (presence_charts.sky_matrix): the spike's "
    "decode (Apple's decoder, As Shot white balance, no lens correction, no noise reduction) times 0.5435, the level at "
    "which Lightroom's raw tone curve sees the ARW (measured on round 1's bases, scratch/sky_level.py), rendered through "
    "the Embedded profile, a matrix alone. Its base sky has the ARW's level and chroma (L* 84.3 against 85.3, C* 17.6 "
    "both) but another hue (268 against 250 degrees): the profile's tables already turn the base. First look, not a fit "
    "(scratch/sky_hue.py: CIELAB D50 on 4 x 4 blocks, the base's blue blocks in the top 40 %, the hue of their mean a* "
    "and b*): at +100 the sky turns +26.7 degrees under Adobe Standard (per-block median +23.8; F2 measured +24) and -6.0 "
    "through the matrix (median -6.2); at +50, +8.4 and -2.7. The DNG's demosaic, noise and white balance are the "
    "spike's: compare r-sky-matrix only with its own base. Whether its Dehaze repeats was not tested (photographs did, "
    "the charts did not, and it is a DNG of a photograph).",
    "**White object (F2 request 4).** r-haze-white's 0.95 patch renders at L* 99.7 at the base (largest code 65256, "
    "nothing clipped) and every one of its 4096 pixels is at 65535 in each render at +50 and +100 (three at +100): "
    "Lightroom does not guard the clip. Away from the patch (a 128-pixel margin) r-haze-white's base equals "
    "r-haze-neutral's to the code. At +100 the two charts differ there by a mean of 15.6 to 22.9 codes over the four "
    "pairs of renders, but two renders of r-haze-white differ by 16.1: whether the patch moves the rest of the frame "
    "cannot be told from Dehaze's own scatter here (scratch/scatter_shape.py).",
    "**Between the knots (F2 request 1, F3 request 3).** r-haze-neutral and r-colour-grid-tif hold every value from -100 "
    "to +100 (10, 25, 50, 75, 100 of each sign) in one job with their base, so the values asked for need no knot from "
    "another session. r-colour-grid-tif's shared renders equal round 1's. r-haze-neutral's carry the chart scatter "
    "above: its -25 and +100 equal round 1's, its -100, -50, +25 and +50 do not.",
    "**Colour grid (F3 requests 1 and 2).** r-colour-grid holds its base, Exposure +1 and -1 alone, Saturation +50 and "
    "Vibrance +100 and -100 alone, and each control beside each Exposure. Against the same Exposure alone, mean chroma "
    "moves the control's way in all six pairs (Saturation +50: +15.3 at +1, +12.4 at -1; Vibrance +100: +14.6, +12.5; "
    "Vibrance -100: -20.3, -22.5; `pairs`). Patches whose interior median has a channel at 65535, of 1929 "
    "(scratch/first_look.py): base 46, Exposure +1 129, +1 with Saturation +50 466, with Vibrance +100 199, with "
    "Vibrance -100 6; at code 0: base 262 (the grid's edge colours), +1 with Saturation +50 520, Saturation +50 alone 696, "
    "-1 with Saturation +50 862. Leave those patches out.",
    "**Photographs.** Round 2's twenty frames, nine renders each with its own base, held out from the Dehaze, Vibrance and "
    "Saturation fits; their round-2 renders are Clarity and Texture only. Every sanity check holds on all twenty: the "
    "dark channel falls at Dehaze +50 and +100 and rises at -100, chroma rises at +50 and +100 and falls at -100.",
    "**Clipping, measured (`stats.black` and `stats.white`: pixels with a channel at code 0 or 65535, of 32,741,376).** "
    "Saturation +100 sends a channel to 0 on 18.1 million pixels of r-photo-mirror-lights (55 %), 13.7 million of "
    "-flower and 13.4 million of -magenta-night; Vibrance +100 on 7.8 million of -magenta-night and 6.0 million of "
    "-disco; Dehaze +100 on 4.0 million of -mirror-lights and 3.1 million of -hall. The night frames clip at their base "
    "already (-mirror-lights 3.3 million at 0, 0.25 million at 65535). In a ProPhoto export a channel at 0 is a colour "
    "pushed past the gamut or a black crushed: leave those pixels out of fits in chroma or in log units.",
]}


def holdout_table(rows, jobs_by_name):
    """Round 3's photographs: Lightroom's statistics of each base, and whether it is the earlier round's base again."""
    lines = ["| Job | Frame | Scene | L* | Spread | Dark | Chroma | Fine | Local | Base against the earlier round's |",
             "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
    for r in rows:
        lr, twin = r.get("lightroomBase", {}), jobs_by_name[r["job"]].get("twin")
        cell = "" if not twin else f"{twin['job']}: " + ("identical" if twin["identical"] else
                                                          f"{twin.get('codesDiffer', float('nan')):.1%} of codes differ, "
                                                          f"at most {twin.get('max', '?')}, mean {twin.get('mean', float('nan')):.2f}")
        lines.append(f"| {r['job']} | `{Path(r['source']).name}` | {r['scene']} | "
                     + " | ".join(f"{lr.get(k, float('nan')):.{p}f}" for k, p in (("lightness", 2), ("spread", 2), ("dark", 2),
                                                                               ("chroma", 2), ("fine", 3), ("local", 3)))
                     + f" | {cell} |")
    return lines


def frame_table(rows):
    lines = ["| Job | Frame | Scene | Median | Spread | Fine | Coarse | Lightroom fine | Lightroom local | Why chosen |",
             "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |"]
    for r in rows:
        d, lr = r["decode"], r.get("lightroomBase", {})
        lines.append(f"| {r['job']} | `{Path(r['source']).name}` | {r['scene']} | {d['median']:+.2f} | {d['spread']:.2f} | "
                     f"{d['fine']:.3f} | {d['coarse']:.3f} | {lr.get('fine', float('nan')):.3f} | "
                     f"{lr.get('local', float('nan')):.3f} | {r['why']} |")
    return lines


def sameness(d):
    if d.get("identical"):
        return "bit-identical"
    if "codesDiffer" not in d:
        return "**not identical**"
    return f"**differs**, {d['codesDiffer']:.1%} of codes, at most {d['max']}, mean {d['mean']:.2f}"


def markdown(m):
    number = m.get("round", 1)
    lines = [f"# Presence probe{'' if number == 1 else f', round {number}'}: manifest", "",
             f"Made by `scripts/lightroom-probe/presence_plan.py manifest{'' if number == 1 else f' --round {number}'}` on "
             f"{m['made']} from the job files and the exports themselves. `manifest.json` holds the same and more (every "
             f"statistic, every applied setting).", "",
             f"{m['totals']['exports']} exports, {m['totals']['bytes'] / 1e9:.2f} GB. {len(m['wrong'])} look wrong.", "",
             "## Read this first", ""] + [f"- {note}" for note in NOTES[number]] + [""]
    if m.get("frames") and "decode" not in m["frames"][0]:
        lines += ["## Photographs", "",
                  "Lightroom's statistics of each photograph's base (presence_stats: mean L*, its spread, the dark "
                  "channel's mean L*, mean chroma C*ab, and `fine` and `local` on the central 2048 crop), and how the "
                  "base compares with the same frame's base from an earlier round, code by code. Round 2's manifest "
                  "holds each frame's quick-decode measures and why it was chosen.", ""] + \
                 holdout_table(m["frames"], {j["name"]: j for j in m["jobs"]}) + [""]
    elif m.get("frames"):
        lines += ["## Photographs", "",
                  "Measures of each frame's quick decode (`presence_plan.scene_measures` on `argent-spike "
                  f"{' '.join(str(a) for a in DECODE)}`, the scene the film render receives, linear Rec. 2020, middle "
                  "grey 0.18), in stops over middle grey: the median, the spread from the 10th to the 90th percentile, "
                  "`fine` (rms log2 detail under a 3-pixel box, about 4 to 12 full-size pixels) and `coarse` (a 5-pixel "
                  "box less a 65-pixel box, about 20 to 260 full-size pixels). Lightroom's `fine` and `local` are "
                  "presence_stats' on the full-size base export (5 and 65 pixels, central 2048 crop), noise included.",
                  ""] + frame_table(m["frames"]) + [""]
    if m.get("earlierFrames"):
        lines += ["Round 1's photographs, measured the same way:", ""] + frame_table(m["earlierFrames"]) + [""]
    lines += ["## Sanity", "",
              "Each control's statistic on each source, as the change from the base (`presence_stats.py`: `fine` and "
              "`local` are rms log2 detail at 5 and 65 pixels, `dark` the mean L* of min(R, G, B), `chroma` the mean "
              "C*ab). `ok` means it moved the way the control implies, and more at 100 than at 50.", "",
              "| Job | Control | Statistic | Base | Change by value | Verdict |", "| --- | --- | --- | ---: | --- | --- |"]
    for r in m["sanity"]:
        change = ", ".join(f"{int(k):+d}: {v:+.4g}" for k, v in r["change"].items())
        lines.append(f"| {r['job']} | {r['control']} | {r['statistic']} | {r['base']:.4g} | {change} | {r['verdict']} |")
    if m.get("pairs"):
        lines += ["", "Renders that set a Presence control beside another setting: each Presence control's statistic "
                  "against the render without it (the base, or the same Exposure alone), which it should move the way "
                  "the control moves it alone.", "", "| Job | Render | Against | Change | Verdict |",
                  "| --- | --- | --- | --- | --- |"]
        lines += [f"| {r['job']} | {r['label']} | {r.get('against', '00_base')} | "
                  f"{', '.join(f'{k} {v:+.4g}' for k, v in r['change'].items())} | {r['verdict']} |" for r in m["pairs"]]
    lines += ["", "## Exports that look wrong", "",
              "Missing, not as asked (a setting, the profile or a look), or the same pixels as the base:", ""]
    lines += [f"- `{w['path']}`: {w['problem']}" for w in m["wrong"]] or ["None."]
    repeats = {(j["name"], label) for j in m["jobs"] for label in j.get("repeats", {})}
    nearly = [e for e in m["exports"] if e.get("stats", {}).get("dE", 1) < 0.01 and (e["job"], e["label"]) not in repeats]
    lines += ["", "Nearly unchanged from the base (mean Delta E under 0.01 over 4 x 4 blocks), all real renders whose "
              "pixels differ from the base:", ""]
    lines += [f"- `{e['path']}`: mean Delta E {e['stats']['dE']:.4f}" for e in nearly] or ["None."]
    lines += ["", "## Jobs", ""]
    by_job = {}
    for e in m["exports"]:
        by_job.setdefault(e["job"], []).append(e)
    for j in m["jobs"]:
        lines += [f"### {j['name']}", "", f"- Source: `{j['source']}` ({j['kind']}). {j['why']}.",
                  f"- Exports: `{j['exports']}/`, {j['renders']} renders." + (f" Layout: `{j['layout']}`." if j["layout"] else "")]
        if j.get("twin"):
            t = j["twin"]
            detail = "pixel digests" if "codesDiffer" not in t or t["identical"] else \
                f"{t['codesDiffer']:.1%} of codes differ, at most {t['max']} of 65535, mean {t['mean']:.2f}"
            lines.append(f"- Base {'bit-identical to' if t['identical'] else '**differs from**'} `{t['base']}`, the same "
                         f"source's base in {t.get('job', 'round 1')}{' (this session)' if t.get('sameRound') else ''} "
                         f"({detail}).")
            lines += [f"- `{label}` against {t['job']}'s `{other['of']}`, the same settings: {sameness(other)}."
                      for label, other in t.get("renders", {}).items() if label != "00_base"]
        for label, r in j.get("repeats", {}).items():
            r = r if isinstance(r, dict) else {"of": "00_base", "identical": r}
            lines.append(f"- `{label}` asks for `{r['of']}`'s settings again in this job: {sameness(r)}.")
        lines += ["", "| Export | Settings asked (on top of the neutral base) | Mean ΔE from the base |", "| --- | --- | ---: |"]
        for e in by_job.get(j["name"], []):
            settings = "; ".join(f"{k}={v}" for k, v in e.get("settings", {}).items()) or "none"
            change = f"{e['stats']['dE']:.3f}" if "dE" in e.get("stats", {}) else ""
            lines.append(f"| `{e['path']}` | {settings}{' **' + e['problem'] + '**' if e.get('problem') else ''} | {change} |")
        lines.append("")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    li = sub.add_parser("list")
    w = sub.add_parser("write")
    w.add_argument("jobs", nargs="+", help="job names, or `all` for every job of the round")
    m = sub.add_parser("manifest")
    m.add_argument("out")
    m.add_argument("--markdown-only", action="store_true", help="rewrite manifest.md from manifest.json, reading no export")
    for p in (li, w, m):
        p.add_argument("--round", type=int, default=1, choices=sorted(PLANS))
    f = sub.add_parser("frames")
    f.add_argument("out")
    args = parser.parse_args()
    if args.command == "list":
        listing(args.round)
    elif args.command == "write":
        write([j.name for j in PLANS[args.round]()] if args.jobs == ["all"] else args.jobs)
    elif args.command == "frames":
        frames(Path(args.out))
    elif args.markdown_only:
        out = Path(args.out)
        (out / "manifest.md").write_text(markdown(json.loads((out / "manifest.json").read_text())))
    else:
        manifest(Path(args.out), args.round)


if __name__ == "__main__":
    main()
