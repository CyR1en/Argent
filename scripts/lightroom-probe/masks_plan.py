"""The mask session's experiments (SESSION.md beside this file).

One session at Lightroom Classic with the owner present settles what Argent's mask arithmetic should
copy before Phase 1 freezes it. Every experiment here is a *table job*: a photo, the plain develop
settings, and a `MaskGroupBasedCorrections` table the plug-in writes with `photo:applyDevelopSettings`.
No AI mask, no pointer gesture. This module is the catalogue: which items, in which job, for which
question, and what the session costs. `jobs.py masks` writes the files; `analyze_masks.py` reads the
exports back with the same plan, and `synth_masks.py` renders it with laws of its own so the analysis
can be tried without Lightroom.

Questions (PHASE0.md, masking-plan.md section 9):
    Q1 partial coverage: does a partial mask scale the slider or the gain
    Q2 overlap: how two masks combine, both orders, and whether list order matters
    Q3 Amount: its range and what it scales
    Q4 feather profile: radial at several Feather values, linear gradients
    Q5 component algebra: Add, Subtract, Intersect, Invert of crossing gradients
    Q6 the base: whether a mask's Highlights and Shadows read the same local base as the global ones
    Q7 local and global together: the order, and whether a mask over everything equals the control
    Q8 ranges: local Exposure's range and scale, and the other sliders'

Charts (all real linear DNGs, since Lightroom ignores settings embedded in TIFFs):
    R  mask-ramp.dng, 2000 x 1200: every row the same ramp, 12 stops under white to white
    F  mask-flat.dng, 1600 x 1000: one flat field 2.5 stops under white (about mid-gray)
    F2 mask-flat-half.dng, 800 x 500: the same at half the size, for resolution independence
    L, AD, AB  the 2026-10-29 locality chart and the dark and bright adaptation charts
    P  one a7 IV raw (the CC0 sample the earlier probe used), for whole-frame equality on a real picture
"""
import json
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_charts  # noqa: E402
import probe  # noqa: E402

PLAN_VERSION = 1
CATALOG_GUARD = "argent-masks-session"

# Controls: letter -> (global develop key, local key in a correction, divisor from the panel's number to the stored one).
# The divisors are third-party measurements on Lightroom 15.6 (GW capture 2, MCP-304/317): Exposure is stored as
# EV / 4 (panel range -4...4), the other tone sliders as panel / 100.
CONTROLS = {
    "E": ("Exposure2012", "LocalExposure2012", 4.0),
    "C": ("Contrast2012", "LocalContrast2012", 100.0),
    "H": ("Highlights2012", "LocalHighlights2012", 100.0),
    "S": ("Shadows2012", "LocalShadows2012", 100.0),
    "W": ("Whites2012", "LocalWhites2012", 100.0),
    "B": ("Blacks2012", "LocalBlacks2012", 100.0),
}
TONE = ["C", "H", "S", "W", "B"]
LOCAL_TYPE = ["H", "S"]
GLOBAL_TYPE = ["W", "B", "C"]

# Planning cost per item in seconds, by chart, and per job. The only throughput on record is the 2026-10-29
# run: at least 175 renders (97 DNG charts of 6-7 MP, 78 raws of 33 MP; the research note counts 196) whose jobs
# were written at 23:03 and logged done by 23:07, so at most 4 minutes: under 0.5 s a 6-7 MP chart and under
# 2.5 s a raw, if time follows pixels. These costs are 2 to 4 times that, because a fresh catalog builds its
# caches and masks add work.
CHARTS = {
    "R": {"file": "mask-ramp.dng", "mp": 2.4, "sec": 1.0},
    "F": {"file": "mask-flat.dng", "mp": 1.6, "sec": 0.8},
    "F2": {"file": "mask-flat-half.dng", "mp": 0.4, "sec": 0.6},
    "L": {"file": "locality.dng", "mp": 7.2, "sec": 1.8},
    "AD": {"file": "adapt-dark.dng", "mp": 6.0, "sec": 1.6},
    "AB": {"file": "adapt-bright.dng", "mp": 6.0, "sec": 1.6},
    "P": {"file": "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW", "mp": 33.0, "sec": 3.5, "raw": True},
    # m06-confirm only: scenes unlike P and unlike each other. The other CC0 samples are P's scene, so they cannot test frame independence.
    "P2": {"file": "Y-JG-SONY-A7-IV-0255.ARW", "mp": 33.0, "sec": 3.5, "corpus": True},  # high key: a dog on snow
    "P3": {"file": "Y-JG-SONY-A7-IV-0602.ARW", "mp": 33.0, "sec": 3.5, "corpus": True},  # low key: dusk, dark trees under a bright sky
}
JOB_OVERHEAD = 12.0  # seconds a job spends on its export session and bookkeeping, apart from its items
SESSION_SETUP_MIN = 15  # SESSION.md: catalog, install, launch, smoke check
SESSION_WRAPUP_MIN = 12  # SESSION.md: quit, collect, analysis, revert, delete the catalog


def stored(ctrl, value):
    """The number a correction holds for the panel value `value` of control `ctrl` (six decimals, as Lightroom keeps)."""
    return round(value / CONTROLS[ctrl][2], 6)


def fmt(value):
    """+50, -1.5, +0.25: a signed number for ids."""
    return f"{value:+g}"


# MARK: Components and corrections (Lightroom's own field names; see MaskJob.lua)

def component(what, op="add", invert=False, **fields):
    c = {"What": what, "MaskActive": True, "MaskBlendMode": 1 if op == "sub" else 0, "MaskInverted": bool(invert),
         "MaskValue": 0 if op == "sub" else 1, "MaskName": what.split("/")[-1]}
    c.update(fields)
    return c


def linear(full, zero, op="add", invert=False):
    """A linear gradient: coverage 1 at and beyond `full`, 0 at and beyond `zero`; (x, y) in 0...1, origin top left, y down."""
    return component("Mask/Gradient", op, invert, ZeroX=zero[0], ZeroY=zero[1], FullX=full[0], FullY=full[1])


def radial(left, top, right, bottom, feather=50, angle=0, roundness=0, midpoint=50, op="add", invert=False):
    return component("Mask/CircularGradient", op, invert, Top=top, Left=left, Bottom=bottom, Right=right, Angle=angle,
                     Feather=feather, Midpoint=midpoint, Roundness=roundness, Version=2)


def lumrange(a, b, c, d, op="add", invert=False):
    return component("Mask/RangeMask", op, invert,
                     CorrectionRangeMask={"Type": 2, "Version": 3, "SampleType": 0, "LumRange": f"{a:g} {b:g} {c:g} {d:g}"})


def intersect(c):
    """The same component as an Intersect, which Lightroom stores as a subtracted, inverted one (KOST24, MCP-325)."""
    out = dict(c)
    out["MaskBlendMode"], out["MaskValue"], out["MaskInverted"] = 1, 0, not c["MaskInverted"]
    return out


def inverted(c):
    out = dict(c)
    out["MaskInverted"] = not c["MaskInverted"]
    return out


def correction(values, comps, amount=1.0, name="c"):
    """A correction (one mask in Lightroom's list): `values` are panel numbers by control letter."""
    c = {"What": "Correction", "CorrectionName": name, "CorrectionActive": True, "CorrectionAmount": amount,
         "CorrectionMasks": comps}
    for ctrl, value in values.items():
        c[CONTROLS[ctrl][1]] = stored(ctrl, value)
    return c


# Four ways to cover the whole frame, to be compared with the global control (Q7). `grad`, the one the other jobs use, puts
# every row of the frame beyond the Full line of a gradient whose points are inside the picture (the last row or so is
# partly covered); `far` does the same with points outside it, which a third party reports Lightroom keeps unchanged but
# which has not been seen here; `lum` is a luminance trapezoid that spans everything (R1: what Lightroom writes in place of
# an invalid range); `rad` is an inverted radial box far outside the frame.
def full_gradient():
    return linear(full=(0.5, 0.999), zero=(0.5, 1.0))


def full_gradient_far():
    return linear(full=(0.5, 3.0), zero=(0.5, 4.0))


def full_range():
    return lumrange(0, 0, 1, 1)


def full_radial():
    return radial(-5, -5, -4, -4, feather=0, invert=True)


FULLS = {"grad": full_gradient, "far": full_gradient_far, "lum": full_range, "rad": full_radial}

# Gradients, in the chart's normalized coordinates (origin top left, y down), as (Full point, Zero point).
GEOM = {
    "G1": ((0.5, 0.15), (0.5, 0.85)),   # down the frame: covered at the top
    "GA": ((0.5, 0.10), (0.5, 0.70)),   # the overlapping pair for Q2: GA covers the top ...
    "GB": ((0.5, 0.90), (0.5, 0.30)),   # ... GB the bottom; both reach 0.3 to 0.7
    "GV": ((0.5, 0.15), (0.5, 0.85)),   # on the flat chart: vertical
    "GH": ((0.15, 0.5), (0.85, 0.5)),   # horizontal
    "GS": ((0.5, 0.45), (0.5, 0.55)),   # a short span
    "GD": ((0.2, 0.2), (0.8, 0.8)),     # diagonal
}
# A circle of radius 480 px on the 1600 x 1000 flat chart (the box is in the chart's normalized coordinates).
RADIAL_BOX = (0.2, 0.02, 0.8, 0.98)


def geometry(name, op="add", invert=False):
    full, zero = GEOM[name]
    return linear(full, zero, op, invert)


# MARK: The plan

@dataclass
class Item:
    id: str
    job: str
    chart: str
    glob: dict            # plain develop settings by crs key
    masks: list | None    # the MaskGroupBasedCorrections table, or None for none
    meta: dict = field(default_factory=dict)

    @property
    def stem(self):
        return f"{self.job}_{self.id}"

    def to_json(self):
        return {"id": self.id, "job": self.job, "chart": self.chart, "glob": self.glob, "masks": self.masks, "meta": self.meta}


@dataclass
class Job:
    name: str
    title: str
    gate: int = 0         # stop the whole run if this many mask items fail the read-back
    items: list = field(default_factory=list)


class Plan:
    def __init__(self):
        self.jobs = []
        self.items = {}

    def job(self, name, title, gate=0):
        job = Job(name, title, gate)
        self.jobs.append(job)
        return job

    def add(self, job, id, chart, glob=None, masks=None, **meta):
        """Adds an item to `job` unless an identical one exists (then returns its id); a different one under the same id is a bug."""
        item = Item(id, job.name, chart, dict(glob or {}), masks, meta)
        if id in self.items:
            old = self.items[id]
            assert (old.chart, old.glob, old.masks) == (chart, item.glob, masks), f"two different items called {id}"
            return id
        self.items[id] = item
        job.items.append(item)
        return id

    def select(self, **where):
        """Items whose meta (or chart, job, id) holds every key=value of `where`."""
        def has(i, k, v):
            return (getattr(i, k) if k in ("chart", "job", "id") else i.meta.get(k)) == v
        return [i for i in self.items.values() if all(has(i, k, v) for k, v in where.items())]

    def get(self, id):
        return self.items[id]

    def estimate(self):
        """Seconds per job, items times the chart's planning cost plus the job's overhead; and the total in minutes for the session."""
        per_job = []
        for job in self.jobs:
            seconds = JOB_OVERHEAD + sum(CHARTS[i.chart]["sec"] for i in job.items)
            per_job.append((job.name, job.title, len(job.items), seconds))
        run = sum(s for *_, s in per_job) / 60
        gb = sum(CHARTS[i.chart]["mp"] * 1e6 * 6 for i in self.items.values()) / 1e9   # 16-bit RGB TIFFs
        return {"jobs": per_job, "run_min": run, "total_min": SESSION_SETUP_MIN + run + SESSION_WRAPUP_MIN, "export_gb": gb}

    def summary(self):
        est = self.estimate()
        lines = [f"{'job':<14} {'items':>5} {'planned':>8}  what"]
        for name, title, n, s in est["jobs"]:
            lines.append(f"{name:<14} {n:>5} {s / 60:>6.1f} m  {title}")
        lines.append(f"{'':<14} {sum(n for _, _, n, _ in est['jobs']):>5} {est['run_min']:>6.1f} m  Lightroom's run, planned")
        lines.append(f"session: {SESSION_SETUP_MIN} min setup + {est['run_min']:.0f} min run + {SESSION_WRAPUP_MIN} min wrap-up = {est['total_min']:.0f} min; "
                     f"the exports take about {est['export_gb']:.1f} GB of disk")
        return "\n".join(lines)

    def to_json(self):
        return {"version": PLAN_VERSION, "catalog": CATALOG_GUARD, "estimate": self.estimate(),
                "jobs": [{"name": j.name, "title": j.title, "gate": j.gate, "items": [i.id for i in j.items]} for j in self.jobs],
                "items": {i.id: i.to_json() for i in self.items.values()}}


def locality_edges():
    """x, as a share of the width, of the centres of the locality chart's 512- and 64-pixel squares (the same in every band)."""
    _, layout = make_charts.locality()
    centres = {}
    for sq in layout["squares"]:
        if sq["row"] == make_charts.ROWS[0][0] and sq["size"] in (512, 64):
            centres[sq["size"]] = (sq["box"][0] + sq["size"] / 2) / layout["width"]
    return centres


E_RAMP = [-3, -2, -1.5, -1, -0.5, -0.25, 0.25, 0.5, 0.75, 1, 1.5, 2, 3]
E_FLAT = [-4, -3, -2, -1.5, -1, -0.75, -0.5, -0.25, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]
E_HALF = [-2, -1.5, -1, -0.5, -0.25, 0.25, 0.5, 1, 1.5, 2]
TONE_VALUES = [-100, -75, -50, -25, 25, 50, 75, 100]
# One value of each control for the pair matrix: moderate, and the sign in which each does most.
PAIR_VALUES = {"E": 1.0, "C": 50, "H": -50, "S": 50, "W": 50, "B": -50}
STRONG_PAIRS = [(("W", 100), ("B", -100)), (("C", 100), ("W", 100)), (("H", -100), ("S", 100))]
HALF_STRENGTH = {"C": 50, "H": -50, "S": 50, "W": 50, "B": -50}
STRONG_SIGNS = {"C": (100, -100), "H": (-100, 100), "S": (100, -100), "W": (100, -100), "B": (-100, 100)}


def gid(chart, pairs):
    """Id of a global render: R-gW+50_B-50, F-gE+1."""
    return f"{chart}-g" + "_".join(f"{c}{fmt(v)}" for c, v in pairs)


def glob_of(pairs):
    return {CONTROLS[c][0]: v for c, v in pairs}


def _ref(plan, job, chart, pairs, **meta):
    meta.setdefault("q", "REF")
    return plan.add(job, gid(chart, pairs), chart, glob_of(pairs), role="global", ctrl="".join(c for c, _ in pairs),
                    values=[v for _, v in pairs], **meta)


def _base(plan, job, chart):
    return plan.add(job, f"{chart}-base", chart, role="base", q="REF")


def _full(plan, job, id, chart, values, kind="grad", amount=1.0, **meta):
    return plan.add(job, id, chart, masks=[correction(values, [FULLS[kind]()], amount)], role="mask", cover=kind, **meta)


def _smoke(plan):
    job = plan.job("m00-smoke", "go/no-go: base, global Exposure +1, and local Exposure +1 through six kinds of table", gate=3)
    _base(plan, job, "R")
    _ref(plan, job, "R", [("E", 1)])
    for kind in FULLS:
        _full(plan, job, f"R-smoke-{kind}-E+1", "R", {"E": 1}, kind, q="SMOKE", ctrl="E", value=1)
    plan.add(job, "R-smoke-G1-E+1", "R", masks=[correction({"E": 1}, [geometry("G1")])], role="mask", q="SMOKE", ctrl="E", value=1, geom="G1")
    plan.add(job, "R-smoke-radial-E+1", "R", masks=[correction({"E": 1}, [radial(0.25, 0.1, 0.75, 0.9, feather=50)])],
             role="mask", q="SMOKE", ctrl="E", value=1)
    _full(plan, job, "R-smoke-amount0.5-E+2", "R", {"E": 2}, amount=0.5, q="SMOKE", ctrl="E", value=2)


def _partial(plan):
    job = plan.job("m01-partial", "Q1 partial coverage, Q3 Amount, Q7 whole-frame equality, Q8 ranges of the other sliders (ramp)")
    for e in E_RAMP:
        _ref(plan, job, "R", [("E", e)])
    for c in TONE:
        for v in TONE_VALUES:
            _ref(plan, job, "R", [(c, v)])
    _ref(plan, job, "R", [("W", 50), ("B", -50)])
    _ref(plan, job, "R", [("W", 100), ("B", -100)])
    # Q1: one linear gradient down the ramp: each control at +-100 and at half strength; Exposure, for the coverage itself
    for c in TONE:
        for v in (*STRONG_SIGNS[c], HALF_STRENGTH[c]):
            plan.add(job, f"R-q1-G1-{c}{fmt(v)}", "R", masks=[correction({c: v}, [geometry("G1")])], role="mask", q="Q1",
                     ctrl=c, value=v, geom="G1", amount=1.0)
    for e in (2, 1, -1, -2):
        plan.add(job, f"R-q1-G1-E{fmt(e)}", "R", masks=[correction({"E": e}, [geometry("G1")])], role="mask", q="Q1",
                 ctrl="E", value=e, geom="G1", amount=1.0)
    # Q3: Amount on a mask over everything, and on a gradient
    for a in (0, 0.25, 0.5, 0.75, 1.5, 2, 3):
        _full(plan, job, f"R-q3-E+1-a{a:g}", "R", {"E": 1}, amount=a, q="Q3", ctrl="E", value=1)
        plan.get(f"R-q3-E+1-a{a:g}").meta["amount"] = a
    for a in (0.25, 0.5, 0.75):
        _full(plan, job, f"R-q3-W+100-a{a:g}", "R", {"W": 100}, amount=a, q="Q3", ctrl="W", value=100)
        plan.get(f"R-q3-W+100-a{a:g}").meta["amount"] = a
    for c, v in (("B", -100), ("H", -100), ("S", 100), ("C", 100)):
        _full(plan, job, f"R-q3-{c}{fmt(v)}-a0.5", "R", {c: v}, amount=0.5, q="Q3", ctrl=c, value=v)
        plan.get(f"R-q3-{c}{fmt(v)}-a0.5").meta["amount"] = 0.5
    plan.add(job, "R-q3-W+100_B-100-a0.5", "R", masks=[correction({"W": 100, "B": -100}, [full_gradient()], 0.5)], role="mask", q="Q3",
             ctrl="WB", value=[100, -100], amount=0.5, cover="grad")
    plan.add(job, "R-q3-G1-E+2-a0.5", "R", masks=[correction({"E": 2}, [geometry("G1")], 0.5)], role="mask", q="Q3",
             ctrl="E", value=2, amount=0.5, geom="G1")
    plan.add(job, "R-q3-G1-W+100-a0.5", "R", masks=[correction({"W": 100}, [geometry("G1")], 0.5)], role="mask", q="Q3",
             ctrl="W", value=100, amount=0.5, geom="G1")
    # Q7: a gradient that covers the frame, each control at +-50 and +-100, Exposure at +-0.5, 1, 2
    for c in TONE:
        for v in (100, -100, 50, -50):
            _full(plan, job, f"R-q7-full-{c}{fmt(v)}", "R", {c: v}, q="Q7", ctrl=c, value=v)
    for e in (0.5, 1, 2, -0.5, -1, -2):
        _full(plan, job, f"R-q7-full-E{fmt(e)}", "R", {"E": e}, q="Q7", ctrl="E", value=e)
    # Q8: past the sliders' range
    for c, v in (("W", 150), ("B", -150)):
        _full(plan, job, f"R-q8-full-{c}{fmt(v)}", "R", {c: v}, q="Q8", ctrl=c, value=v)
    # the noise floor: the same settings again, in another file
    plan.add(job, "R-rep-base", "R", role="base", q="REP", of="R-base")
    plan.add(job, "R-rep-gW+100", "R", glob=glob_of([("W", 100)]), role="global", q="REP", of="R-gW+100", ctrl="W", values=[100])


def pair_items(plan, job, a, b, tag="Q2"):
    """The four renders of two controls at full coverage on the ramp: one mask holding both sliders, two masks in both
    orders, and the global panel holding both. a, b = (letter, panel value)."""
    (ca, va), (cb, vb) = a, b
    key = f"{ca}{fmt(va)}_{cb}{fmt(vb)}"
    full = lambda values: correction(values, [full_gradient()])
    meta = dict(q=tag, a=ca, va=va, b=cb, vb=vb)
    plan.add(job, f"R-q2-{key}-one", "R", masks=[full({ca: va, cb: vb})], role="pair-one", **meta)
    plan.add(job, f"R-q2-{key}-ab", "R", masks=[full({ca: va}), full({cb: vb})], role="pair-ab", **meta)
    plan.add(job, f"R-q2-{key}-ba", "R", masks=[full({cb: vb}), full({ca: va})], role="pair-ba", **meta)
    _ref(plan, job, "R", [(ca, va), (cb, vb)], pair=key)


def twice_items(plan, job, c, v):
    """The same control in two masks, each at v: against one mask and the global panel at 2v (renders of m01)."""
    plan.add(job, f"R-q2-{c}{fmt(v)}x2", "R", masks=[correction({c: v}, [full_gradient()]), correction({c: v}, [full_gradient()])],
             role="pair-twice", q="Q2", a=c, va=v, b=c, vb=v)


def _overlap(plan):
    job = plan.job("m02-overlap", "Q2 how two masks combine, both orders, and partial overlap; Q7 local and global together (ramp)")
    order = list(PAIR_VALUES)
    for i, a in enumerate(order):
        for b in order[i + 1:]:
            pair_items(plan, job, (a, PAIR_VALUES[a]), (b, PAIR_VALUES[b]))
    for c, v in PAIR_VALUES.items():
        twice_items(plan, job, c, v)
    for a, b in STRONG_PAIRS:
        pair_items(plan, job, a, b)
    # partial overlap: two gradients that cross each other's edge; their coverage comes from Exposure on the same geometry
    def single(ctrl, value, geom):
        return plan.add(job, f"R-pp-{ctrl}{fmt(value)}-{geom}", "R", masks=[correction({ctrl: value}, [geometry(geom)])],
                        role="pp-single", q="PP", ctrl=ctrl, value=value, geom=geom)
    for (ca, va, ga), (cb, vb, gb) in ((("W", 100, "GA"), ("B", -100, "GB")), (("W", 100, "GA"), ("W", 100, "GB")),
                                        (("E", 1.5, "GA"), ("E", 1.5, "GB")), (("C", 100, "GA"), ("W", 100, "GB"))):
        single(ca, va, ga)
        single(cb, vb, gb)
        key = f"{ca}{fmt(va)}-{ga}_{cb}{fmt(vb)}-{gb}"
        ma = correction({ca: va}, [geometry(ga)])
        mb = correction({cb: vb}, [geometry(gb)])
        meta = dict(q="PP", a=ca, va=va, ga=ga, b=cb, vb=vb, gb=gb)
        plan.add(job, f"R-pp-{key}-ab", "R", masks=[ma, mb], role="pp-ab", **meta)
        plan.add(job, f"R-pp-{key}-ba", "R", masks=[mb, ma], role="pp-ba", **meta)
    # Q7: the global panel and one mask over everything together, either way round
    for (ga, va), (mb, vb) in ((("W", 50), ("B", -50)), (("B", -50), ("W", 50)), (("C", 50), ("W", 50)), (("W", 50), ("C", 50)),
                               (("E", 1), ("H", -50)), (("H", -50), ("E", 1))):
        plan.add(job, f"R-lg-g{ga}{fmt(va)}-m{mb}{fmt(vb)}", "R", glob=glob_of([(ga, va)]),
                 masks=[correction({mb: vb}, [full_gradient()])], role="local-global", q="Q7", g=ga, vg=va, m=mb, vm=vb)


def _feather(plan):
    job = plan.job("m03-feather", "Q4 feather profile, Q5 component algebra, Q8 local Exposure's range (flat chart, and its half-size twin)")
    _base(plan, job, "F")
    for e in E_FLAT:
        _ref(plan, job, "F", [("E", e)])
    box = RADIAL_BOX
    for feather in (0, 10, 25, 50, 75, 100):
        for e in (2, -2):
            plan.add(job, f"F-q4-rad-f{feather}-E{fmt(e)}", "F", masks=[correction({"E": e}, [radial(*box, feather=feather)])],
                     role="mask", q="Q4", shape="radial", feather=feather, ctrl="E", value=e)
    plan.add(job, "F-q4-rad-f50-inv-E+2", "F", masks=[correction({"E": 2}, [radial(*box, feather=50, invert=True)])],
             role="mask", q="Q4", shape="radial", feather=50, invert=True, ctrl="E", value=2)
    plan.add(job, "F-q4-ell30-f50-E+2", "F", masks=[correction({"E": 2}, [radial(0.1, 0.25, 0.9, 0.75, feather=50, angle=30)])],
             role="mask", q="Q4", shape="ellipse", feather=50, angle=30, ctrl="E", value=2)
    for key, kwargs in (("mid25", {"midpoint": 25}), ("mid75", {"midpoint": 75}), ("rnd+50", {"roundness": 50}), ("rnd-50", {"roundness": -50})):
        plan.add(job, f"F-q4-rad-f50-{key}-E+2", "F", masks=[correction({"E": 2}, [radial(*box, feather=50, **kwargs)])],
                 role="mask", q="Q4", shape="radial", feather=50, variant=key, ctrl="E", value=2)
    for g, es in (("GV", (1, -1, 2, -2)), ("GS", (1,)), ("GH", (1,)), ("GD", (1,))):
        for e in es:
            plan.add(job, f"F-q4-{g}-E{fmt(e)}", "F", masks=[correction({"E": e}, [geometry(g)])], role="mask", q="Q4",
                     shape="linear", geom=g, ctrl="E", value=e)
    # Q5: two gradients that cross, a third, and every way of combining them
    A, B = geometry("GV"), geometry("GH")
    C = radial(*box, feather=50)
    algebra = {
        "A+B": [A, B], "B+A": [B, A], "A-B": [A, geometry("GH", "sub")], "B-A": [B, geometry("GV", "sub")],
        "AxB": [A, intersect(B)], "BxA": [B, intersect(A)], "invA": [inverted(A)],
        "A+invB": [A, inverted(B)], "invA+invB": [inverted(A), inverted(B)], "invAxB": [inverted(A), intersect(B)],
        "A+B+C": [A, B, C], "C": [C],
    }
    for name, comps in algebra.items():
        plan.add(job, f"F-q5-{name}", "F", masks=[correction({"E": 1}, comps)], role="mask", q="Q5", algebra=name, ctrl="E", value=1)
    # Q8: local Exposure through and past its range, on the flat chart
    for e in (0.5, 1, 2, 3, 4, 5, 6, -1, -2, -4, -5):
        _full(plan, job, f"F-q8-full-E{fmt(e)}", "F", {"E": e}, q="Q8", ctrl="E", value=e)
    # the same shapes at half the size: does the edge scale with the picture
    _base(plan, job, "F2")
    for e in E_HALF:
        _ref(plan, job, "F2", [("E", e)])
    plan.add(job, "F2-q4-rad-f50-E+2", "F2", masks=[correction({"E": 2}, [radial(*box, feather=50)])], role="mask", q="Q4",
             shape="radial", feather=50, ctrl="E", value=2)
    plan.add(job, "F2-q4-rad-f50-E-2", "F2", masks=[correction({"E": -2}, [radial(*box, feather=50)])], role="mask", q="Q4",
             shape="radial", feather=50, ctrl="E", value=-2)
    plan.add(job, "F2-q4-GV-E+1", "F2", masks=[correction({"E": 1}, [geometry("GV")])], role="mask", q="Q4", shape="linear", geom="GV",
             ctrl="E", value=1)
    plan.add(job, "F-rep-base", "F", role="base", q="REP", of="F-base")


def _base_job(plan, edges):
    job = plan.job("m04-base", "Q6 does a mask read the global base; Q7 a mask over everything on a real picture")
    _base(plan, job, "L")
    for c, v in (("H", -100), ("S", 100)):
        _ref(plan, job, "L", [(c, v)], q="Q6")
        _full(plan, job, f"L-q6-full-{c}{fmt(v)}", "L", {c: v}, q="Q6", ctrl=c, value=v)
        for size, x in edges.items():
            # a hard vertical edge through the middle of the square of that size: covered to the left of it
            comps = [linear(full=(x - 0.0005, 0.5), zero=(x + 0.0005, 0.5))]
            plan.add(job, f"L-q6-edge{size}-{c}{fmt(v)}", "L", masks=[correction({c: v}, comps)], role="mask", q="Q6",
                     ctrl=c, value=v, edge=size, edge_x=x)
    for chart in ("AD", "AB"):
        _base(plan, job, chart)
        for c, v in (("H", -100), ("S", 100)):
            _ref(plan, job, chart, [(c, v)], q="Q6")
            _full(plan, job, f"{chart}-q6-full-{c}{fmt(v)}", chart, {c: v}, q="Q6", ctrl=c, value=v)
            # only the ramp band (the top 20 % of the frame) is covered, far from the content below it
            plan.add(job, f"{chart}-q6-band-{c}{fmt(v)}", chart,
                     masks=[correction({c: v}, [linear(full=(0.5, 0.15), zero=(0.5, 0.19))])], role="mask", q="Q6", ctrl=c, value=v, band=True)
    # a real picture: the global panel against a mask over everything, and a gradient
    _base(plan, job, "P")
    for c, v in (("E", 1), ("H", -100), ("S", 100), ("W", 50), ("B", -50), ("C", 50)):
        _ref(plan, job, "P", [(c, v)], q="Q7")
        _full(plan, job, f"P-q7-full-{c}{fmt(v)}", "P", {c: v}, q="Q7", ctrl=c, value=v)


def _extra(plan):
    job = plan.job("m05-extra", "Q7 the other three ways to cover the frame (points outside the picture, a luminance range, an inverted radial)")
    for kind in ("far", "lum", "rad"):
        for c, v in (("W", 100), ("H", -100), ("S", 100), ("E", 1)):
            _full(plan, job, f"R-q7-{kind}-{c}{fmt(v)}", "R", {c: v}, kind, q="Q7", ctrl=c, value=v)


def _confirm(plan):
    """m06-confirm, from the audit of the first session (P0-L1b): what no export of m00 to m05 can decide. Its `q` tags end in x so that
    analyze_masks.py, which answers Q1 to Q8 from m00 to m05, reads the same items as before; m06 is read by the audit's own scripts."""
    job = plan.job("m06-confirm", "radial family, ellipse, invert; H/S against Exposure on real pictures; Amount beyond 1; other pictures; panel with a mask; W and B together")
    box = RADIAL_BOX
    # a. the radial feather family at Exposure -2, and the half-size twin of the hard edge and of Feather 100
    for f in (5, 15, 20, 35, 60, 85):
        plan.add(job, f"F-q4-rad-f{f}-E-2", "F", masks=[correction({"E": -2}, [radial(*box, feather=f)])], role="mask", q="Q4x", shape="radial", feather=f, ctrl="E", value=-2)
    for f in (0, 100):
        plan.add(job, f"F2-q4-rad-f{f}-E-2", "F2", masks=[correction({"E": -2}, [radial(*box, feather=f)])], role="mask", q="Q4x", shape="radial", feather=f, ctrl="E", value=-2)
    # b. ellipses, Feather 50, Exposure -2: how a box and an angle map to an ellipse
    wide, square = (0.1, 0.25, 0.9, 0.75), (0.2, 0.2, 0.8, 0.8)
    for name, b, ang, f in (("wide-a0", wide, 0, 50), ("wide-a30", wide, 30, 50), ("wide-a90", wide, 90, 50), ("wide-a-30", wide, -30, 50),
                            ("sq-a0", square, 0, 50), ("sq-a45", square, 45, 50), ("wide-a0-f100", wide, 0, 100)):
        plan.add(job, f"F-q4-ell-{name}-E-2", "F", masks=[correction({"E": -2}, [radial(*b, feather=f, angle=ang)])], role="mask", q="Q4x", shape="ellipse", feather=f, angle=ang, ctrl="E", value=-2)
    # c. inverted radials
    for f in (10, 25, 75):
        plan.add(job, f"F-q4-rad-f{f}-inv-E-2", "F", masks=[correction({"E": -2}, [radial(*box, feather=f, invert=True)])], role="mask", q="Q4x", shape="radial", feather=f, invert=True, ctrl="E", value=-2)
    plan.add(job, "F-q4-ell-wide-a0-inv-E-2", "F", masks=[correction({"E": -2}, [radial(*wide, feather=50, invert=True)])], role="mask", q="Q4x", shape="ellipse", feather=50, invert=True, ctrl="E", value=-2)
    # d. Highlights and Shadows against Exposure on real pictures, panel and mask; `far` gradients, so the last rows are covered
    _ref(plan, job, "P", [("E", -1)], q="Q7x")
    for e in (1, -1):
        for c, v in (("H", -100), ("S", 100)):
            _ref(plan, job, "P", [("E", e), (c, v)], q="Q7x", pair=f"E{fmt(e)}_{c}{fmt(v)}")
            plan.add(job, f"P-lg-g{c}{fmt(v)}-mE{fmt(e)}", "P", glob=glob_of([(c, v)]), masks=[correction({"E": e}, [full_gradient_far()])], role="local-global", q="Q7x", g=c, vg=v, m="E", vm=e)
    for e in (1, -1):
        plan.add(job, f"P-q7x-one-E{fmt(e)}_H-100", "P", masks=[correction({"E": e, "H": -100}, [full_gradient_far()])], role="mask", q="Q7x", cover="far", ctrl="EH", value=[e, -100])
    _base(plan, job, "P3")
    for pairs in ([("E", 1)], [("E", -1)], [("H", -100)], [("S", 100)]):
        _ref(plan, job, "P3", pairs, q="Q7x")
    for e in (1, -1):
        for c, v in (("H", -100), ("S", 100)):
            _ref(plan, job, "P3", [("E", e), (c, v)], q="Q7x", pair=f"E{fmt(e)}_{c}{fmt(v)}")
    # e. Amount beyond 1 for the tone controls, and the product value x Amount against the slider's range
    for c, v in (("W", 100), ("B", -100), ("H", -100), ("S", 100), ("C", 100)):
        _full(plan, job, f"R-q3-{c}{fmt(v)}-a2", "R", {c: v}, amount=2, q="Q3x", ctrl=c, value=v, amount_read=2)
    _full(plan, job, "R-q3-W+100-a1.5", "R", {"W": 100}, amount=1.5, q="Q3x", ctrl="W", value=100, amount_read=1.5)
    _full(plan, job, "R-q3-W+50-a2", "R", {"W": 50}, amount=2, q="Q3x", ctrl="W", value=50, amount_read=2)
    _full(plan, job, "R-q3-E+1-a2.5", "R", {"E": 1}, amount=2.5, q="Q3x", ctrl="E", value=1, amount_read=2.5)
    # f. Whites and Blacks together in one mask, on a grid: are they one levels stretch?
    for w in (25, 50, 100):
        for b in (-25, -50, -100, 50):
            plan.add(job, f"R-q2x-W{fmt(w)}_B{fmt(b)}-one", "R", masks=[correction({"W": w, "B": b}, [full_gradient_far()])], role="pair-one", q="Q2x", w=w, b=b)
    # g. other scenes: are a mask's Whites, Blacks and Contrast the same curves on any picture? (option B rests on this)
    for chart in ("P2", "P3"):
        if chart == "P2":
            _base(plan, job, chart)
        for c, v in (("W", 50), ("B", -50), ("C", 50)):
            _ref(plan, job, chart, [(c, v)], q="Q7x")
            _full(plan, job, f"{chart}-q7-far-{c}{fmt(v)}", chart, {c: v}, kind="far", q="Q7x", ctrl=c, value=v)
    # h. Highlights and Shadows, local against panel, at +-50 on the real picture
    for c, v in (("H", -50), ("S", 50)):
        _ref(plan, job, "P", [(c, v)], q="Q6x")
        _full(plan, job, f"P-q7-far-{c}{fmt(v)}", "P", {c: v}, kind="far", q="Q6x", ctrl=c, value=v)
    # i. Whites, Blacks and Contrast at their strongest on the real picture (m04 has only +-50)
    for c, v in (("W", 100), ("B", -100), ("C", 100)):
        _ref(plan, job, "P", [(c, v)], q="Q7x")
        _full(plan, job, f"P-q7-far-{c}{fmt(v)}", "P", {c: v}, kind="far", q="Q7x", ctrl=c, value=v)
    # j. the panel and a mask on the same control: do they add sliders, add gains, or follow one another?
    for c, v in (("E", 1), ("H", -50), ("S", 50), ("W", 50), ("B", -50), ("C", 50)):
        plan.add(job, f"R-lgx-g{c}{fmt(v)}-m{c}{fmt(v)}", "R", glob=glob_of([(c, v)]), masks=[correction({c: v}, [full_gradient_far()])], role="local-global", q="Q7x", g=c, vg=v, m=c, vm=v)


def _render_law(plan):
    """m07-law, from P0-L1c: the render law "sum the sliders, evaluate once" had only been seen on the ramp and at sums up to 100.
    Masks that overlap on a real picture, sums past 100 across masks, three masks, and Amount 2 on the sign m06 did not try."""
    job = plan.job("m07-law", "the render law on a real picture: overlapping masks, sums past 100 across masks, three masks, Amount 2 on the other sign")
    far = full_gradient_far

    def masks(*values):
        return [correction(v, [far()], name="abc"[i]) for i, v in enumerate(values)]

    # a. two masks over everything against one holding both, on the real picture
    for a, b in ((("W", 50), ("B", -50)), (("C", 50), ("W", 50)), (("H", -50), ("S", 50))):
        pair = f"{a[0]}{fmt(a[1])}_{b[0]}{fmt(b[1])}"
        plan.add(job, f"P-o-{pair}-ab", "P", masks=masks(dict([a]), dict([b])), role="pair", q="Qo", pair=pair, order="ab")
        plan.add(job, f"P-o-{pair}-one", "P", masks=masks({**dict([a]), **dict([b])}), role="pair-one", q="Qo", pair=pair)
    plan.add(job, "P-o-W+50_B-50-ba", "P", masks=masks({"B": -50}, {"W": 50}), role="pair", q="Qo", pair="W+50_B-50", order="ba")
    # b. the same control in two masks, against one mask at the sum (P-q7-far-W+100 is in m06)
    plan.add(job, "P-o-W+50x2", "P", masks=masks({"W": 50}, {"W": 50}), role="pair", q="Qo", pair="W+50x2")
    plan.add(job, "P-o-H-50x2", "P", masks=masks({"H": -50}, {"H": -50}), role="pair", q="Qo", pair="H-50x2")
    _full(plan, job, "P-q7-far-H-100", "P", {"H": -100}, kind="far", q="Qo", ctrl="H", value=-100)
    # c. gradients that overlap in a band, on the real picture, in both orders
    a, b = {"W": 50}, {"B": -50}
    plan.add(job, "P-pp-W+50-GA_B-50-GB-ab", "P", masks=[correction(a, [geometry("GA")], name="a"), correction(b, [geometry("GB")], name="b")], role="pair", q="Qo", order="ab")
    plan.add(job, "P-pp-W+50-GA_B-50-GB-ba", "P", masks=[correction(b, [geometry("GB")], name="b"), correction(a, [geometry("GA")], name="a")], role="pair", q="Qo", order="ba")
    # d. the panel and a mask on the same control, on the real picture
    for c, v in (("C", 50), ("W", 50), ("H", -50)):
        plan.add(job, f"P-lgx-g{c}{fmt(v)}-m{c}{fmt(v)}", "P", glob=glob_of([(c, v)]), masks=masks({c: v}), role="local-global", q="Qo", g=c, vg=v, m=c, vm=v)
    # e. sums past 100 across masks, against Amount 2 on one mask (m06 has those for this sign)
    for c, v in (("W", 100), ("B", -100), ("C", 100), ("H", -100), ("S", 100)):
        plan.add(job, f"R-o-{c}{fmt(v)}x2", "R", masks=masks({c: v}, {c: v}), role="pair", q="Qo", ctrl=c, value=v)
    plan.add(job, "R-o-W+100x3", "R", masks=masks({"W": 100}, {"W": 100}, {"W": 100}), role="pair", q="Qo", ctrl="W", value=100)
    # f. three masks against one holding all three, and in reverse order
    trio = ({"C": 50}, {"W": 50}, {"B": -50})
    plan.add(job, "R-o-C+50_W+50_B-50-abc", "R", masks=masks(*trio), role="pair", q="Qo", order="abc")
    plan.add(job, "R-o-C+50_W+50_B-50-cba", "R", masks=masks(*reversed(trio)), role="pair", q="Qo", order="cba")
    plan.add(job, "R-o-C+50_W+50_B-50-one", "R", masks=masks({**trio[0], **trio[1], **trio[2]}), role="pair-one", q="Qo")
    # g. Amount 2 on the sign m06 did not try, so the rows past 100 are measured on both signs
    for c, v in (("W", -100), ("B", 100), ("H", 100), ("S", -100), ("C", -100)):
        _full(plan, job, f"R-q3-{c}{fmt(v)}-a2", "R", {c: v}, amount=2, q="Q3x", ctrl=c, value=v, amount_read=2)


def build():
    plan = Plan()
    _smoke(plan)
    _partial(plan)
    _overlap(plan)
    _feather(plan)
    _base_job(plan, locality_edges())
    _extra(plan)
    _confirm(plan)
    _render_law(plan)
    return plan


# MARK: Writing the jobs

def source_path(chart, charts_dir, root=None):
    entry = CHARTS[chart]
    if entry.get("corpus"):
        return (Path(root) if root else probe.ROOT) / "references" / "corpus" / "imaging-resource-a7iv-gallery" / entry["file"]
    if entry.get("raw"):
        folder = os.environ.get("ARGENT_PROBE_SAMPLES")
        return Path(folder) / entry["file"] if folder else (Path(root) if root else probe.ROOT) / "samples" / entry["file"]
    return Path(charts_dir) / entry["file"]


def clone(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        subprocess.run(["cp", "-c", str(source), str(target)], check=True)
    return target


def job_text(plan, job, root, charts_dir, out_dir, allow_missing=False, repo_root=None):
    """The text of `job`'s file and the files it names: [(path, bytes)] to write, [(source, target)] to clone."""
    lines = [f"CATALOG\t{CATALOG_GUARD}", "MODE\tmasks", f"OUT\t{out_dir}", f"NOTE\t{job.title}"]
    if job.gate:
        lines.append(f"GATE\t{job.gate}")
    tables, clones = [], []
    for item in job.items:
        source = source_path(item.chart, charts_dir, repo_root)
        if not source.exists() and not allow_missing:
            raise SystemExit(f"{source} is missing (chart {item.chart}); make_charts.py masks writes the new charts")
        target = Path(root) / "inputs" / job.name / f"{item.stem}{source.suffix.lower()}"
        clones.append((source, target))
        settings = ";".join(f"{k}={v:g}" for k, v in item.glob.items())
        table = ""
        if item.masks:
            table = str(Path(root) / "mask-tables" / job.name / f"{item.id}.json")
            tables.append((table, json.dumps(item.masks, indent=None, sort_keys=True).encode() + b"\n"))
        lines.append(f"ITEM\t{target}\t{settings}\t{table}")
    return "\n".join(lines) + "\n", tables, clones


def write_plan(plan, root, jobs_dir, charts_dir, allow_missing=False, only=None, repo_root=None):
    """Writes everything the session needs under `root` (inputs, mask tables, masks-plan.json) and the job files into `jobs_dir`;
    the caller has checked READY if jobs_dir is the plug-in's. Returns the job names written."""
    root, jobs_dir = Path(root), Path(jobs_dir)
    jobs_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for job in plan.jobs:
        if only and job.name not in only:
            continue
        text, tables, clones = job_text(plan, job, root, charts_dir, root / f"exports-{job.name}", allow_missing, repo_root)
        for path, data in tables:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            Path(path).write_bytes(data)
        for source, target in clones:
            if source.exists():
                clone(source, target)
        tmp = jobs_dir / f"{job.name}.job.tmp"
        tmp.write_text(text)
        tmp.rename(jobs_dir / f"{job.name}.job")
        written.append(job.name)
    (root / "masks-plan.json").write_text(json.dumps(plan.to_json(), indent=1, sort_keys=True))
    return written


def load_plan(path):
    """The plan a session wrote, from masks-plan.json, as a Plan."""
    data = json.loads(Path(path).read_text())
    plan = Plan()
    for j in data["jobs"]:
        job = plan.job(j["name"], j["title"], j["gate"])
        for id in j["items"]:
            d = data["items"][id]
            item = Item(d["id"], d["job"], d["chart"], d["glob"], d["masks"], d["meta"])
            plan.items[id] = item
            job.items.append(item)
    return plan


def export_path(item, root):
    return Path(root) / f"exports-{item.job}" / f"{item.stem}.tif"


if __name__ == "__main__":
    print(build().summary())
