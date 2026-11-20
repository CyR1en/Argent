"""What the mask session found, in numbers: eight questions, each answered from Lightroom's exports against Argent's candidate rule.

    python -I analyze_masks.py check   [--root DIR]
    python -I analyze_masks.py all     [--root DIR] [--out DIR] [--block 4]
    python -I analyze_masks.py q1|q2|q3|q4|q5|q6|q7|q8 [--root DIR]

`--root` is the folder holding masks-plan.json and the exports-<job>/ folders the plug-in filled (default
references/lightroom-probe). Exports are read as the rest of this probe reads them: `probe.py`'s uncompressed 16-bit
ProPhoto reader (the same as references/lightroom-probe/kit/tiffread.py), CIE L* of the linear luminance, averaged over
4 x 4 blocks in linear light. Nothing is written but the report (`--out`, default ROOT/masks-report).

Every question compares Lightroom with Argent's candidate (R5's arithmetic and R8's constants, docs/masking-plan.md
sections 4 and 6) and says which rule to adopt and what keeping the current one costs, in L*. R5's arithmetic here runs on
tables built from Lightroom's own whole-frame renders (mask_models.RampTables), so that what is measured is the *law of
composition and coverage*, not the film's transfer; R5's Swift harness (cpuref.swift) needs Argent's stock LUTs and its
`ManualToneTables`, which are built from the film, so it cannot take Lightroom's tables without a new initializer.
test_masks.py checks this Python port of R5's arithmetic against that harness when a Swift compiler is at hand.

The method, for the coverage a mask really has: Exposure is a pure gain in stops, so a mask of local Exposure E over a
flat or ramp chart, read against the chart's global Exposure series, gives the coverage at every pixel: the exposure e* that
reproduces the observed L*, over E. That is `alpha`. Three readings of "coverage" are kept apart (alpha in stops, in L*
and in luminance); the one for which alpha does not depend on E is the law (section Q1).
"""
import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mask_models as mm  # noqa: E402
import masks_plan  # noqa: E402
import probe  # noqa: E402

BLOCK = 4
TOL_EQUAL = 0.30      # L*: below this two renders count as the same (the replicates give the floor)
VISIBLE = 1.0         # L*: a control's effect must exceed this at a column to be used there


def stat(diff):
    d = np.asarray(diff, float)
    d = d[np.isfinite(d)]
    if d.size == 0:
        return {"rms": None, "p95": None, "max": None, "n": 0}
    a = np.abs(d)
    return {"rms": float(np.sqrt(np.mean(d * d))), "p95": float(np.percentile(a, 95)), "max": float(a.max()), "n": int(d.size)}


def fmt(x, digits=2):
    if x is None or (isinstance(x, (float, np.floating)) and not math.isfinite(x)):
        return "n/a"
    text = f"{x:.{digits}f}"
    return text[1:] if text.startswith("-") and float(text) == 0 else text


class Result:
    """What a question found: markdown lines for the report, a verdict dict a program can read, a status."""

    def __init__(self, key, title):
        self.key, self.title = key, title
        self.lines, self.verdict, self.status = [], {}, "ok"

    def add(self, text=""):
        self.lines.append(text)

    def table(self, header, rows):
        self.add("| " + " | ".join(header) + " |")
        self.add("| " + " | ".join("---" for _ in header) + " |")
        for row in rows:
            self.add("| " + " | ".join(str(c) for c in row) + " |")
        self.add()

    def missing(self, what):
        self.status = "missing"
        self.add(f"**Not run: {what}.**")
        return self

    def markdown(self):
        return "\n".join([f"## {self.title}", "", f"_status: {self.status}_", ""] + self.lines)


# MARK: Data

class Data:
    """The session's exports by item id, as block-averaged L*."""

    def __init__(self, plan, root, extra=(), block=BLOCK, cache=None):
        self.plan, self.root, self.block = plan, Path(root), block
        self.extra = [Path(e) for e in extra]
        self.cache = Path(cache) if cache else None
        self._L = {}

    def path(self, id):
        item = self.plan.items.get(id)
        if item is None:
            return None
        found = masks_plan.export_path(item, self.root)
        if found.exists():
            return found
        for folder in self.extra:
            for candidate in (folder / found.name, folder / f"exports-{item.job}" / found.name):
                if candidate.exists():
                    return candidate
        return None

    def has(self, *ids):
        return all(self.path(i) is not None for i in ids)

    def L(self, id):
        if id not in self._L:
            path = self.path(id)
            if path is None:
                raise KeyError(id)
            cache = self.cache / f"{id}.b{self.block}.npy" if self.cache else None
            if cache and cache.exists() and cache.stat().st_mtime >= path.stat().st_mtime:
                self._L[id] = np.load(cache)
            else:
                value = probe.lstar(probe.block_mean(probe.lightroom_luminance(path), self.block).astype(np.float64))
                if cache:
                    cache.parent.mkdir(parents=True, exist_ok=True)
                    np.save(cache, value)
                self._L[id] = value
        return self._L[id]

    def done_lines(self, kind):
        """The WARN/NOTE/ERROR lines the plug-in logged (jobs/<job>.done beside the plan, or the .processed folder)."""
        out = []
        for folder in [self.root / "jobs", self.root.parent / "jobs", *self.extra]:
            for path in sorted(Path(folder).glob("*.done")) if Path(folder).exists() else []:
                for line in path.read_text().splitlines():
                    if line.startswith(kind):
                        out.append(f"{path.stem}: {line}")
        return out


def global_items(plan, chart, ctrl):
    """value -> id of the single-control global renders of `ctrl` on `chart`."""
    return {i.meta["values"][0]: i.id for i in plan.items.values()
            if i.chart == chart and i.meta.get("role") == "global" and i.meta.get("ctrl") == ctrl and len(i.meta.get("values", [])) == 1
            and i.meta.get("q") != "REP"}


class Chart:
    """A chart's base render, its global Exposure series and (on the ramp) each control's global renders: the tools to turn an
    observed L* into the coverage that made it, and to predict what a rule would give."""

    def __init__(self, data, name):
        self.d, self.name = data, name
        base = data.L(f"{name}-base")
        self.rows, self.cols = base.shape
        self.base = base
        self.ramp = name == "R"
        self.x = -12 + 12 * (np.arange(self.cols) + 0.5) / self.cols if self.ramp else np.full(self.cols, masks_plan.make_charts.MASK_FLAT_STOPS)
        self.base_cols = np.median(base, axis=0)
        self.v = (np.arange(self.rows) + 0.5) / self.rows
        self.u = (np.arange(self.cols) + 0.5) / self.cols
        es = global_items(data.plan, name, "E")
        es = {e: i for e, i in es.items() if data.has(i)}
        self.E_ids = es
        series = [self.base_cols] + [np.median(data.L(i), axis=0) for e, i in sorted(es.items())]
        self.expo = mm.ExposureResponse([0.0] + sorted(es), series) if len(es) >= 3 else None
        self.E_cols = {e: np.median(data.L(i), axis=0) for e, i in es.items()}
        self.tables = None
        self.transfer = None
        if self.ramp:
            # T beyond the ramp's own range: a column at level x under Exposure e shows T(x + e)
            xs, Ls = [self.x], [self.base_cols]
            for e, cols in self.E_cols.items():
                xs.append(self.x + e)
                Ls.append(cols)
            X, Lv = np.concatenate(xs), np.concatenate(Ls)
            grid = np.arange(X.min(), X.max() + 0.02, 0.02)
            bins = np.clip(np.digitize(X, grid) - 1, 0, len(grid) - 1)
            sums = np.bincount(bins, Lv, len(grid))
            counts = np.bincount(bins, None, len(grid))
            have = counts > 0
            self.transfer = (grid[have], sums[have] / counts[have])
            glob = {}
            for ctrl in "CHSWB":
                for v, i in global_items(data.plan, name, ctrl).items():
                    if data.has(i):
                        glob[(ctrl, float(v))] = np.median(data.L(i), axis=0)
            self.tables = mm.RampTables(self.x, self.base_cols, glob, self.transfer) if glob else None

    def usable(self, margin=3.0, border=0.03):
        """Columns whose base render is neither black nor white, away from the picture's side edges."""
        ok = (self.base_cols > margin) & (self.base_cols < 100 - margin)
        if self.ramp:
            ok &= (self.u > border) & (self.u < 1 - border)
        return ok

    def alpha(self, obs, e, kind="gain", full=None, scale=1.0):
        """The coverage a render shows, given that its mask holds local Exposure `e` (panel EV): kind 'gain' (stops: the exposure
        that reproduces the L*, over the exposure the same mask gives over everything), 'L' (the share of the way, in L*, from
        the base to the full render) or 'Y' (the same in luminance). `full` is the L* of the same mask covering everything
        (job m01's R-q7-full-E…); without it the nominal exposure and the global render at it stand in. NaN where the control
        does nothing visible."""
        usable = self.usable()
        if kind == "gain":
            if full is not None:
                ef = np.nanmedian(self.expo.exposure_of(full)[:, usable])
            else:
                ef = e * scale
            return self.expo.exposure_of(obs) / ef
        fullc = np.median(full, axis=0) if full is not None else self.E_cols.get(e)
        if fullc is None:
            return np.full(obs.shape, np.nan)
        base = self.base_cols[None, :]
        if kind == "L":
            span = fullc[None, :] - base
            a = (obs - base) / np.where(np.abs(span) < 1e-9, np.nan, span)
        else:
            y0, yf, yo = probe.luminance(base), probe.luminance(fullc[None, :]), probe.luminance(obs)
            span = yf - y0
            a = (yo - y0) / np.where(np.abs(span) < 1e-9, np.nan, span)
        return np.where(np.abs(fullc[None, :] - base) > 3.0, a, np.nan)


def row_profile(a, usable=None):
    """Median over the usable columns of each row of a coverage field."""
    if usable is not None:
        a = np.where(usable[None, :], a, np.nan)
    with np.errstate(all="ignore"):
        return np.nanmedian(a, axis=1)


# MARK: Q1 partial coverage

HYPOTHESES = ["gain", "slider", "blendL", "blendY"]


def q1(d):
    r = Result("q1", "Q1. Does a partial mask scale the slider or the gain?")
    ids = {e: f"R-q1-G1-E{masks_plan.fmt(e)}" for e in (2, 1, -1, -2)}
    if not d.has("R-base") or not all(d.has(i) for i in ids.values()):
        return r.missing("the ramp's base, Exposure series and the four G1 Exposure masks (job m01)")
    ch = Chart(d, "R")
    if ch.tables is None or ch.expo is None:
        return r.missing("the ramp's global renders (job m01)")
    usable = ch.usable()
    # 1. the coverage, three ways, from local Exposure at four strengths
    profiles = {}
    spread = {}
    fulls = {e: (d.L(f"R-q7-full-E{masks_plan.fmt(e)}") if d.has(f"R-q7-full-E{masks_plan.fmt(e)}") else None) for e in ids}
    for kind in ("gain", "L", "Y"):
        per = {e: row_profile(ch.alpha(d.L(i), e, kind, fulls[e]), usable) for e, i in ids.items()}
        profiles[kind] = per
        stack = np.array([per[e] for e in sorted(per)])
        mean = np.nanmean(stack, axis=0)
        partial = (mean > 0.05) & (mean < 0.95)
        with np.errstate(all="ignore"):
            spread[kind] = float(np.nanmax((np.nanmax(stack, axis=0) - np.nanmin(stack, axis=0))[partial])) if partial.any() else None
    best_kind = min((k for k in spread if spread[k] is not None), key=lambda k: spread[k], default=None)
    r.add("Coverage from local Exposure +2, +1, -1 and -2 on one linear gradient down the ramp (job m01), read three ways. If a "
          "reading is the law, the coverage it gives does not depend on the Exposure used. The spread is the largest difference "
          "between the four, over the rows where the coverage is between 5 and 95 %:")
    r.add()
    r.table(["reading of coverage", "spread across Exposure +-1, +-2", "reading"],
            [["alpha in stops (gain)", fmt(spread["gain"], 3), "e* / E, e* the exposure that gives the L*"],
             ["alpha in L*", fmt(spread["L"], 3), "(L - L0) / (L(E) - L0)"],
             ["alpha in luminance", fmt(spread["Y"], 3), "(Y - Y0) / (Y(E) - Y0)"]])
    sym = None
    if all(spread[k] is not None for k in spread):
        c_gain_pos = np.nanmean([profiles["gain"][2], profiles["gain"][1]], axis=0)
        c_gain_neg = np.nanmean([profiles["gain"][-2], profiles["gain"][-1]], axis=0)
        part = (c_gain_pos > 0.05) & (c_gain_pos < 0.95)
        sym = float(np.nanmax(np.abs(c_gain_pos - c_gain_neg)[part])) if part.any() else None
    exposure_law = {"gain": "gain", "L": "blendL", "Y": "blendY"}.get(best_kind)
    others = sorted((s for k, s in spread.items() if k != best_kind and s is not None))
    exposure_settled = best_kind is not None and spread[best_kind] < 0.03 and (not others or spread[best_kind] < 0.5 * others[0])
    r.add(f"Exposure's coverage is stops-linear when the first row is the smallest and small (under 0.03): here the best reading is "
          f"**{exposure_law}** (spread {fmt(spread.get(best_kind), 3)}), {'settled' if exposure_settled else 'not clearly separated from the others'}. "
          f"Positive against negative Exposure differ by at most {fmt(sym, 3)}.")
    r.add()
    coverage = {"gain": np.nanmean([profiles["gain"][e] for e in ids], axis=0),
                "L": np.nanmean([profiles["L"][e] for e in ids], axis=0),
                "Y": np.nanmean([profiles["Y"][e] for e in ids], axis=0)}
    c_gain = np.nan_to_num(coverage["gain"], nan=0.0)
    # 2. the tone controls against four hypotheses
    items = [i for i in d.plan.select(q="Q1", geom="G1") if i.meta["ctrl"] in "CHSWB" and d.has(i.id)]
    if not items:
        return r.missing("the tone controls on the gradient (job m01)")
    rows = []
    totals = {h: [] for h in HYPOTHESES}
    decisive = {h: [] for h in HYPOTHESES}
    per_item = []
    for item in sorted(items, key=lambda i: (i.meta["ctrl"], i.meta["value"])):
        ctrl, value = item.meta["ctrl"], float(item.meta["value"])
        obs = d.L(item.id)
        preds = predict_partial(ch, ctrl, value, coverage, 1.0)
        full = ch.tables.L_of_value(ctrl, np.array(value))
        visible = np.abs(full - ch.base_cols) > VISIBLE
        ok = usable & visible & ch.tables.invertible(full)
        partial = (c_gain > 0.08) & (c_gain < 0.92)
        mask = partial[:, None] & ok[None, :]
        errs = {h: stat((preds[h] - obs)[mask]) for h in HYPOTHESES}
        gap = float(np.nanmax(np.abs(preds["gain"] - preds["slider"])[mask])) if mask.any() else 0.0
        for h in HYPOTHESES:
            diff = (preds[h] - obs)[mask]
            totals[h].append(diff)
            if gap > 1.0:
                decisive[h].append(diff)
        winner = min(HYPOTHESES, key=lambda h: errs[h]["rms"] if errs[h]["rms"] is not None else 99)
        per_item.append({"ctrl": ctrl, "value": value, "gap": gap, "errs": errs, "winner": winner})
        rows.append([f"{ctrl}{value:+g}", fmt(gap)] + [f"{fmt(errs[h]['rms'])} / {fmt(errs[h]['max'])}" for h in HYPOTHESES] + [winner if gap > 1.0 else f"({winner})"])
    r.add("Each control through the same gradient, against what each reading predicts from the whole-frame renders (RMS / max |dL*| over the "
          "partial-coverage band; `gap` is how far apart the gain and slider predictions are, so a row with a small gap cannot tell them apart):")
    r.add()
    r.table(["mask", "gap gain/slider L*"] + [f"{h} rms/max" for h in HYPOTHESES] + ["winner"], rows)
    pool = decisive if any(len(v) for v in decisive.values()) else totals
    pooled = {h: stat(np.concatenate(pool[h]) if pool[h] else []) for h in HYPOTHESES}
    best = min(HYPOTHESES, key=lambda h: pooled[h]["rms"] if pooled[h]["rms"] is not None else 99)
    ranked = sorted(HYPOTHESES, key=lambda h: pooled[h]["rms"] if pooled[h]["rms"] is not None else 99)
    second = ranked[1]
    settled = pooled[best]["rms"] is not None and pooled[best]["rms"] < 0.5 * pooled[second]["rms"] and pooled[best]["rms"] < 1.0
    r.add(f"Pooled over the {'decisive' if pool is decisive else 'all'} masks: " +
          ", ".join(f"{h} {fmt(pooled[h]['rms'])} rms / {fmt(pooled[h]['max'])} max" for h in HYPOTHESES) + ".")
    r.add()
    cur = pooled["gain"]
    worst = max(per_item, key=lambda p: p["errs"]["gain"]["max"] or 0)
    r.add(f"**Lightroom: {best if settled else best + ' (not settled)'}.** Argent's current rule (R5: coverage scales the gain in stops, so `gain`) "
          f"{'matches' if best == 'gain' else 'differs'}: its error against Lightroom is {fmt(cur['rms'])} L* rms, {fmt(cur['p95'])} at p95, "
          f"{fmt(cur['max'])} at worst (the worst mask is {worst['ctrl']}{worst['value']:+g}, {fmt(worst['errs']['gain']['max'])} L*).")
    if best == "slider":
        r.add("**Rule to adopt:** coverage scales the *slider* per pixel: build the mask's table at c * V for each pixel. R5's fix is a stack of "
              "tables at c = 0, 1/4, 1/2, 3/4, 1 per mask read at two neighbouring levels and mixed (twice the lookups, +1 day).")
    elif best == "gain":
        r.add("**Rule to adopt:** keep R5's: coverage scales the gain in stops.")
    else:
        r.add(f"**Rule to adopt:** neither of R5's two readings; Lightroom blends the full result with the unmasked one ({best}). Argent can do the same "
              f"in the print stage only by rendering twice, so decide with the owner.")
    r.verdict = {"law": best if settled else "unclear", "best": best, "settled": bool(settled), "exposure_law": exposure_law,
                 "exposure_settled": bool(exposure_settled), "spread": spread, "pooled": pooled,
                 "current_rule_error": cur, "profile": {"v": ch.v.tolist(), "gain": coverage["gain"].tolist()}}
    r.coverage = coverage
    return r


def predict_partial(ch, ctrl, value, coverage, amount):
    """What each reading predicts for `ctrl` at `value` through a mask whose coverage by row (per reading) is `coverage`,
    scaled by `amount` (scaling the coverage; Amount is tested on its own). Shapes (rows, cols)."""
    t = ch.tables
    c = np.nan_to_num(coverage["gain"], nan=0.0) * amount
    out = {}
    g = t.gain_cols(ctrl, value)
    out["gain"] = t.T(ch.x[None, :] + c[:, None] * g[None, :])
    slider = np.empty((len(c), ch.cols))
    for i, ci in enumerate(c):
        slider[i] = t.L_of_value(ctrl, np.array(ci * value))
    out["slider"] = slider
    full = t.L_of_value(ctrl, np.array(value))
    cl = np.nan_to_num(coverage["L"], nan=0.0) * amount
    out["blendL"] = (1 - cl[:, None]) * ch.base_cols[None, :] + cl[:, None] * full[None, :]
    cy = np.nan_to_num(coverage["Y"], nan=0.0) * amount
    out["blendY"] = probe.lstar((1 - cy[:, None]) * probe.luminance(ch.base_cols[None, :]) + cy[:, None] * probe.luminance(full[None, :]))
    return out


# MARK: shared helpers for the ramp questions

def col_median(d, id):
    """A ramp render reduced to one value per column (every row of a whole-frame render is the same)."""
    return np.median(d.L(id), axis=0)


def exposure_full(d, ch, e):
    """The exposure, in stops, that local Exposure `e` gives over everything (job m01's R-q7-full-E…), or None."""
    id = f"R-q7-full-E{masks_plan.fmt(e)}"
    if not d.has(id) or ch.expo is None:
        return None
    return float(np.nanmedian(ch.expo.exposure_of(d.L(id))[:, ch.usable()]))


def sumsq(parts):
    """Pools a list of difference arrays into one stat."""
    flat = [np.asarray(p).ravel() for p in parts if np.asarray(p).size]
    return stat(np.concatenate(flat) if flat else [])


# MARK: Q3 Amount

def q3(d, q1res=None):
    r = Result("q3", "Q3. Amount: its range, and what it scales")
    ch_ok = d.has("R-base", "R-q7-full-E+1")
    if not ch_ok:
        return r.missing("the ramp, its Exposure series and the Amount masks (job m01)")
    ch = Chart(d, "R")
    usable = ch.usable()
    e1 = exposure_full(d, ch, 1)
    # 1. Exposure: what Amount does to a mask that covers everything
    rows = []
    ratios = {}
    for a in (0, 0.25, 0.5, 0.75, 1, 1.5, 2, 3):
        id = f"R-q3-E+1-a{a:g}" if a != 1 else "R-q7-full-E+1"
        if not d.has(id):
            continue
        obs = d.L(id)
        e = ch.expo.exposure_of(obs)
        beyond = float(np.mean(np.isnan(e[:, usable]))) if usable.any() else 0.0
        e_eff = float(np.nanmedian(e[:, usable])) if np.isfinite(e[:, usable]).any() else None
        ratio = None if e_eff is None or not e1 else e_eff / e1
        ratios[a] = ratio
        note = "" if ratio is not None else f"beyond the series ({beyond:.0%} of pixels)"
        rows.append([f"{a:g}", fmt(e_eff, 3), fmt(ratio, 3), fmt(a, 2), note])
    r.add("Local Exposure +1 (stored 0.25) on a mask over everything, at several Amounts; e_eff is the exposure the render shows, in stops, "
          "and the ratio is against Amount 1:")
    r.add()
    r.table(["Amount written", "e_eff (stops)", "ratio to Amount 1", "ratio if linear", "note"], rows)
    linear_to = 0.0
    for a in sorted(ratios):
        if ratios[a] is not None and abs(ratios[a] - a) <= 0.03 * max(1, a):
            linear_to = max(linear_to, a)
    over = {a: ratios[a] for a in ratios if a > linear_to and ratios[a] is not None}
    clamp = max(over.values()) if over else None
    readback = [l for l in d.done_lines("NOTE") if "CorrectionAmount" in l]
    r.add(f"Amount scales Exposure linearly up to **{linear_to:g}**" +
          (f"; above it the render shows at most {fmt(clamp, 2)} of Amount 1's effect (clamped)." if clamp is not None
           else ("; beyond that the render is outside the Exposure series (more than +3 stops), so it was not clamped at 1." if any(
               ratios.get(a) is None for a in (1.5, 2, 3) if a in ratios) else ".")))
    if readback:
        r.add(f"What the plug-in logged on reading the tables back: {readback[0]} (and {len(readback) - 1} more)." if len(readback) > 1 else f"What the plug-in logged: {readback[0]}.")
    r.add()
    # 2. tone controls at full coverage
    items = [i for i in d.plan.select(q="Q3") if i.meta.get("ctrl") in ("W", "B", "H", "S", "C") and "geom" not in i.meta and d.has(i.id)]
    rows, pool = [], {h: [] for h in HYPOTHESES}
    decisive = {h: [] for h in HYPOTHESES}
    for item in sorted(items, key=lambda i: (i.meta["ctrl"], i.meta["amount"])):
        ctrl, v, a = item.meta["ctrl"], float(item.meta["value"]), float(item.meta["amount"])
        obs = col_median(d, item.id)
        t = ch.tables
        full = t.L_of_value(ctrl, np.array(v))
        preds = {"gain": t.T(ch.x + a * t.gain_cols(ctrl, v)), "slider": t.L_of_value(ctrl, np.array(a * v)),
                 "blendL": (1 - a) * ch.base_cols + a * full,
                 "blendY": probe.lstar((1 - a) * probe.luminance(ch.base_cols) + a * probe.luminance(full))}
        ok = usable & (np.abs(full - ch.base_cols) > VISIBLE) & t.invertible(full)
        errs = {h: stat((preds[h] - obs)[ok]) for h in HYPOTHESES}
        gap = float(np.max(np.abs(preds["gain"] - preds["slider"])[ok])) if ok.any() else 0.0
        for h in HYPOTHESES:
            pool[h].append((preds[h] - obs)[ok])
            if gap > 1.0:
                decisive[h].append((preds[h] - obs)[ok])
        winner = min(HYPOTHESES, key=lambda h: errs[h]["rms"] if errs[h]["rms"] is not None else 99)
        rows.append([f"{ctrl}{v:+g} at {a:g}", fmt(gap)] + [f"{fmt(errs[h]['rms'])} / {fmt(errs[h]['max'])}" for h in HYPOTHESES] + [winner if gap > 1.0 else f"({winner})"])
    both = "R-q3-W+100_B-100-a0.5"
    if d.has(both, "R-gW+50_B-50", "R-gW+100_B-100"):
        obs = col_median(d, both)
        t = ch.tables
        full = col_median(d, "R-gW+100_B-100")
        a = 0.5
        preds = {"slider": col_median(d, "R-gW+50_B-50"),
                 "gain": t.T(ch.x + a * (t.Tinv(np.clip(full, t.T_vals[0], t.T_vals[-1])) - ch.x)),
                 "blendL": (1 - a) * ch.base_cols + a * full,
                 "blendY": probe.lstar((1 - a) * probe.luminance(ch.base_cols) + a * probe.luminance(full))}
        ok = usable & (np.abs(full - ch.base_cols) > VISIBLE) & t.invertible(full)
        errs = {h: stat((preds[h] - obs)[ok]) for h in HYPOTHESES}
        gap = float(np.max(np.abs(preds["gain"] - preds["slider"])[ok])) if ok.any() else 0.0
        winner = min(HYPOTHESES, key=lambda h: errs[h]["rms"] if errs[h]["rms"] is not None else 99)
        rows.append(["W+100 and B-100 in one mask at 0.5 (does not vote)", fmt(gap)] + [f"{fmt(errs[h]['rms'])} / {fmt(errs[h]['max'])}" for h in HYPOTHESES] + [winner if gap > 1.0 else f"({winner})"])
    if rows:
        r.add("Tone controls on a mask over everything at Amount a, against four readings (RMS / max |dL*| over the usable columns):")
        r.add()
        r.table(["mask", "gap gain/slider L*"] + [f"{h} rms/max" for h in HYPOTHESES] + ["winner"], rows)
    use = decisive if any(len(v) for v in decisive.values()) else pool
    pooled = {h: sumsq(use[h]) for h in HYPOTHESES}
    best = min(HYPOTHESES, key=lambda h: pooled[h]["rms"] if pooled[h]["rms"] is not None else 99) if rows else None
    second = sorted(HYPOTHESES, key=lambda h: pooled[h]["rms"] if pooled[h]["rms"] is not None else 99)[1] if rows else None
    settled = bool(rows) and pooled[best]["rms"] < 0.5 * pooled[second]["rms"] and pooled[best]["rms"] < 1.0
    if rows:
        r.add("Pooled over the masks that can tell the readings apart: " + ", ".join(f"{h} {fmt(pooled[h]['rms'])} rms / {fmt(pooled[h]['max'])} max" for h in HYPOTHESES) + ".")
        r.add()
    # 3. Amount through a gradient: it multiplies the coverage
    q1res = q1res or q1(d)
    mult = None
    cov = getattr(q1res, "coverage", None)
    gid = "R-q3-G1-E+2-a0.5"
    if cov is not None and d.has(gid) and e1:
        full2 = d.L("R-q7-full-E+2") if d.has("R-q7-full-E+2") else None
        a_half = row_profile(ch.alpha(d.L(gid), 2, "gain", full2), usable)
        c = cov["gain"]
        part = (c > 0.1) & (c < 0.95) & np.isfinite(a_half) & np.isfinite(c)
        if part.any():
            mult = float(np.sum(a_half[part] * c[part]) / np.sum(c[part] ** 2))
            r.add(f"Amount 0.5 through the gradient: the coverage is {fmt(mult, 3)} times the Amount-1 coverage across the band (0.5 if Amount multiplies the coverage).")
            r.add()
    law = best if rows else None
    cur = pooled["slider"] if rows else None
    if rows:
        if best == "slider":
            r.add(f"**Lightroom: Amount scales the slider{'' if settled else ' (not settled)'}.** R5's rule (tables built at Amount x V) matches: its error is {fmt(cur['rms'])} L* rms, {fmt(cur['max'])} at worst. **Keep it.**")
        else:
            r.add(f"**Lightroom: Amount acts on the {best}{'' if settled else ' (not settled)'}.** R5's rule (tables at Amount x V) has an error of {fmt(cur['rms'])} L* rms, "
                  f"{fmt(cur['p95'])} at p95, {fmt(cur['max'])} at worst. **Rule to adopt:** scale the {'gain in stops' if best == 'gain' else 'whole effect'} by Amount, as a coverage.")
    r.verdict = {"law": law if settled else "unclear", "best": law, "settled": bool(settled), "linear_to": linear_to, "clamp": clamp,
                 "pooled": pooled if rows else None, "current_rule_error": cur, "multiplies_coverage": mult, "ratios": {str(k): v for k, v in ratios.items()}}
    return r


# MARK: Q7 a mask over everything, and local with global

def q7(d):
    r = Result("q7", "Q7. A mask over everything, and a mask with the global panel")
    if not d.has("R-base"):
        return r.missing("the ramp (job m01)")
    ch = Chart(d, "R")
    usable = ch.usable()
    rows, diffs = [], []
    for kind in ("grad", "far", "lum", "rad"):
        worst = {}
        for item in d.plan.select(q="Q7", cover=kind, chart="R"):
            if not d.has(item.id):
                continue
            ctrl, v = item.meta["ctrl"], item.meta["value"]
            gid = masks_plan.gid("R", [(ctrl, v)])
            if not d.has(gid):
                continue
            obs, ref = d.L(item.id), col_median(d, gid)
            vis = usable & (np.abs(ref - ch.base_cols) > 0.2)
            delta = (np.median(obs, axis=0) - ref)[vis]
            spread = float(np.max(np.std(obs[:, usable], axis=0))) if usable.any() else 0.0
            worst[(ctrl, v)] = (stat(delta), spread)
        if worst:
            allmax = max(w[0]["max"] for w in worst.values() if w[0]["max"] is not None)
            allrms = max(w[0]["rms"] for w in worst.values() if w[0]["rms"] is not None)
            bad = [f"{c}{v:+g}" for (c, v), (s, _) in worst.items() if s["max"] is not None and s["max"] > TOL_EQUAL]
            rows.append([{"grad": "a gradient beyond its Full line (points inside the picture)", "far": "the same, points outside the picture", "lum": "a luminance range 0 0 1 1", "rad": "an inverted radial outside the frame"}[kind],
                         str(len(worst)), fmt(allrms), fmt(allmax), ", ".join(bad) if bad else "none"])
            diffs.append((kind, allmax, bad))
    if rows:
        r.add("A mask covering everything, against the same control as a global slider, on the ramp (largest RMS and largest |dL*| over the controls and values tried; the replicates give the noise floor):")
        r.add()
        r.table(["way of covering the frame", "renders", "worst rms L*", "worst max L*", "differ by more than %.2f" % TOL_EQUAL], rows)
    rep = []
    for a, b in (("R-base", "R-rep-base"), ("R-gW+100", "R-rep-gW+100")):
        if d.has(a, b):
            rep.append(float(np.max(np.abs(d.L(a) - d.L(b)))))
    floor = max(rep) if rep else None
    if floor is not None:
        r.add(f"Noise floor from the replicates (the same settings in another file): {fmt(floor, 3)} L* at worst.")
        r.add()
    # a real picture
    prow = []
    pdiff = []
    for item in d.plan.select(q="Q7", cover="grad", chart="P"):
        if not d.has(item.id):
            continue
        ctrl, v = item.meta["ctrl"], item.meta["value"]
        gid = masks_plan.gid("P", [(ctrl, v)])
        if not d.has(gid, "P-base"):
            continue
        delta = d.L(item.id) - d.L(gid)
        effect = np.abs(d.L(gid) - d.L("P-base"))
        s = stat(delta)
        pdiff.append(s)
        prow.append([f"{ctrl}{v:+g}", fmt(float(np.mean(effect)), 2), fmt(s["rms"]), fmt(s["p95"]), fmt(s["max"])])
    if prow:
        r.add("On the real a7 IV frame, every pixel (4 x 4 blocks): the mask over everything against the global control:")
        r.add()
        r.table(["control", "mean effect L*", "rms |mask - global|", "p95", "max"], prow)
    ok_grad = next((m for k, m, _ in diffs if k == "grad"), None)
    equal = ok_grad is not None and ok_grad <= TOL_EQUAL
    # local and global together
    lg = [i for i in d.plan.select(q="Q7", role="local-global") if d.has(i.id)]
    order = None
    if lg and ch.tables is not None:
        t = ch.tables
        rows2, err = [], {"mask-first": [], "panel-first": [], "sum": []}
        for item in sorted(lg, key=lambda i: i.id):
            g, vg, m, vm = item.meta["g"], item.meta["vg"], item.meta["m"], item.meta["vm"]
            obs = col_median(d, item.id)
            pair = masks_plan.gid("R", sorted([(g, vg), (m, vm)], key=lambda p: list(masks_plan.PAIR_VALUES).index(p[0])))
            models = {"mask-first": t.r5_lstar(ch.x, ch.x, {g: vg}, [{m: vm}], [1.0], panel_first=False),
                      "panel-first": t.r5_lstar(ch.x, ch.x, {g: vg}, [{m: vm}], [1.0], panel_first=True)}
            if d.has(pair):
                models["sum"] = col_median(d, pair)
            vis = usable & (np.abs(models["mask-first"] - models["panel-first"]) > 0.3)
            if not vis.any():
                vis = usable & (np.abs(obs - ch.base_cols) > VISIBLE)
            e = {k: stat((v - obs)[vis]) for k, v in models.items()}
            for k in e:
                err[k].append((models[k] - obs)[vis])
            best = min(e, key=lambda k: e[k]["rms"])
            informative = bool((np.abs(models["mask-first"] - models["panel-first"])[usable] > 0.3).any())
            rows2.append([f"global {g}{vg:+g} + mask {m}{vm:+g}"] + [f"{fmt(e[k]['rms'])} / {fmt(e[k]['max'])}" if k in e else "n/a" for k in ("mask-first", "panel-first", "sum")] + [best if informative else f"({best}: the two orders agree)"])
        r.add("A mask and the global panel together (RMS / max |dL*| of each rule against the render; columns where the two orders differ):")
        r.add()
        r.table(["combination", "mask first (R5 arithmetic, panel last)", "panel first (R5)", "sum of sliders (the pair on the panel)", "closest"], rows2)
        pooled = {k: sumsq(v) for k, v in err.items() if v}
        order = min(pooled, key=lambda k: pooled[k]["rms"])
        r.add("Pooled: " + ", ".join(f"{k} {fmt(pooled[k]['rms'])} rms / {fmt(pooled[k]['max'])} max" for k in pooled) + ".")
        r.add()
        r.add(f"**Lightroom's rule for a mask and the panel together is closest to: {order}.** R5 puts the panel first: its error is {fmt(pooled['panel-first']['rms'])} L* rms, {fmt(pooled['panel-first']['max'])} at worst. "
              + {"panel-first": "**Keep it.**", "mask-first": "**Rule to adopt:** apply the masks' global gains before the panel's, as the expert reports (local before global).", "sum": "**Rule to adopt:** one evaluation of the summed sliders, panel and masks together."}[order])
    if equal:
        r.add(f"**A mask over everything equals the global control** within {fmt(ok_grad)} L* (gradient construction): Argent's invariant holds.")
    elif diffs:
        r.add(f"**A mask over everything does not equal the global control**: up to {fmt(ok_grad)} L* for the gradient construction. Argent's invariant needs a calibration (list in the table).")
    r.verdict = {"equal": bool(equal), "max_diff": ok_grad, "by_construction": {k: m for k, m, _ in diffs}, "noise_floor": floor,
                 "order": order, "pooled": pooled if lg and ch.tables is not None else None, "r5_pooled": (pooled or {}).get("panel-first") if lg and ch.tables is not None else None}
    return r


# MARK: Q8 ranges

def q8(d):
    r = Result("q8", "Q8. Ranges: local Exposure and the other sliders")
    items = [i for i in d.plan.select(q="Q8", ctrl="E") if d.has(i.id)]
    if not items or not d.has("F-base"):
        return r.missing("the flat chart and the Exposure range masks (job m03)")
    ch = Chart(d, "F")
    rows, ratios, clipped = [], [], None
    top = max((e for e in ch.E_ids), default=None)
    bottom = min((e for e in ch.E_ids), default=None)
    for item in sorted(items, key=lambda i: i.meta["value"]):
        p = float(item.meta["value"])
        obs = float(np.median(d.L(item.id)))
        e = float(ch.expo.exposure_of(np.array([[obs]]))[0, 0])
        prev = [(q, L) for q, L in ((float(j.meta["value"]), float(np.median(d.L(j.id)))) for j in items) if q * p > 0 and abs(q) < abs(p)]
        prev.sort(key=lambda t: abs(t[0]))
        same_as = prev[-1] if prev and abs(prev[-1][1] - obs) < 0.15 else None
        ratio = e / p if np.isfinite(e) else None
        if ratio is not None and abs(p) <= 4 and same_as is None:
            ratios.append(ratio)
        note = f"same as {same_as[0]:+g}: clamped" if same_as else ""
        rows.append([f"{p:+g}", f"{p / 4:+g}", fmt(obs, 2), fmt(e, 3), fmt(ratio, 3), note])
    r.add("Local Exposure through a mask over everything on the flat chart; panel EV is what the plan assumed from the stored value (EV / 4):")
    r.add()
    r.table(["panel EV assumed", "stored", "L* shown", "stops shown", "stops / assumed", "note"], rows)
    scale = float(np.median(ratios)) if ratios else None
    # where the effect stops growing: a value whose render equals the next smaller one's
    shown = sorted(((float(i.meta["value"]), float(np.median(d.L(i.id)))) for i in items), key=lambda t: t[0])
    clip = {}
    for sign in (1, -1):
        seq = [(p, L) for p, L in shown if p * sign > 0]
        seq.sort(key=lambda t: abs(t[0]))
        for (p0, L0), (p1, L1) in zip(seq, seq[1:]):
            if abs(L1 - L0) < 0.15:
                e = float(ch.expo.exposure_of(np.array([[L0]]))[0, 0])
                clip[sign] = {"panel_assumed": p0, "stored": p0 / 4, "stops": e}
                break
    clip_pos, clip_neg = clip.get(1), clip.get(-1)
    r.add(f"Stored = EV / 4 holds: the render shows **{fmt(scale, 3)}** stops per assumed stop (1 means the plan's scale is right)." if scale is not None else "No scale could be read.")
    clip_text = [f"{'+' if sign > 0 else '-'}{abs(c['stored']):g} stored (= {fmt(abs(c['stops']), 2)} stops shown)" for sign, c in clip.items()]
    r.add("Range: " + (f"the effect stops growing past {' and '.join(clip_text)}: clamped." if clip_text else "no clamp seen up to the largest value tried (stored 1.5, +6 EV assumed): check the read-back notes below."))
    notes = [l for l in d.done_lines("NOTE") if "LocalExposure2012" in l]
    if notes:
        r.add(f"The plug-in logged on reading back: {'; '.join(notes[:3])}")
    # the other sliders
    for c, v, ref, name in (("W", 150, "R-q7-full-W+100", "Whites"), ("B", -150, "R-q7-full-B-100", "Blacks")):
        id = f"R-q8-full-{c}{v:+g}"
        if d.has(id, ref, "R-base"):
            ch_r = Chart(d, "R")
            delta = np.max(np.abs(col_median(d, id) - col_median(d, ref))[ch_r.usable()])
            r.add(f"{name} written at {v:+g}: differs from {v // abs(v) * 100:+d} by at most {fmt(float(delta))} L* " + ("(clamped at 100)." if delta < TOL_EQUAL else "(not clamped)."))
    r.add()
    r.verdict = {"exposure_scale": scale, "clip_pos": clip_pos, "clip_neg": clip_neg, "stored_to_ev": (4 * scale if scale else None)}
    return r


# MARK: Q2 how two masks combine

MODELS2 = ["sum", "r5", "seq", "gainsum"]


def _model_set(ch, x, steps, one=None, kscale=1.0):
    """Predictions (columns) of the four readings for two layers `steps` = [(ctrl, value), (ctrl, value)] in list order, both at full coverage."""
    t = ch.tables
    ev = lambda c, v: v * kscale if c == "E" else v
    layers = [{c: ev(c, v)} for c, v in steps]
    out = {"r5": t.r5_lstar(x, x, {}, layers, [1.0] * len(layers)),
           "seq": t.T(mm.seq_level(t, x, [(c, ev(c, v)) for c, v in steps])),
           "gainsum": t.T(x + sum(t.gain(c, ev(c, v), x) for c, v in steps))}
    if one is not None:
        out["sum"] = one
    return out


def q2(d, q1res=None):
    r = Result("q2", "Q2. How do two masks combine, and does list order matter?")
    if not d.has("R-base") or not d.plan.select(q="Q2", role="pair-ab"):
        return r.missing("the ramp (job m01) and the pair renders (job m02)")
    ch = Chart(d, "R")
    if ch.tables is None:
        return r.missing("the ramp's global renders (job m01)")
    t, usable = ch.tables, ch.usable()
    k = 1.0
    if ch.expo is not None:
        scales = [exposure_full(d, ch, e) / e for e in (1, 2) if exposure_full(d, ch, e)]
        k = float(np.mean(scales)) if scales else 1.0
    rows, per_model = [], {m: [] for m in MODELS2}
    order_diffs, orders = [], []
    for ab in sorted(d.plan.select(q="Q2", role="pair-ab"), key=lambda i: i.id):
        a, va, b, vb = ab.meta["a"], ab.meta["va"], ab.meta["b"], ab.meta["vb"]
        key = f"{a}{masks_plan.fmt(va)}_{b}{masks_plan.fmt(vb)}"
        ids = {"ab": f"R-q2-{key}-ab", "ba": f"R-q2-{key}-ba", "one": f"R-q2-{key}-one", "glob": masks_plan.gid("R", [(a, va), (b, vb)])}
        if not d.has(*ids.values()):
            continue
        obs = {n: col_median(d, i) for n, i in ids.items()}
        steps = {"ab": [(a, va), (b, vb)], "ba": [(b, vb), (a, va)]}
        visible = np.abs(obs["glob"] - ch.base_cols) > VISIBLE
        ok = usable & visible
        for single in (t.L_of_value(c, np.array(v)) for c, v in ((a, va), (b, vb)) if c != "E"):
            ok &= t.invertible(single)
        if not ok.any():
            continue
        order_d = stat((obs["ab"] - obs["ba"])[ok])
        order_diffs.append((key, order_d))
        cell = {}
        for o in ("ab", "ba"):
            models = _model_set(ch, ch.x, steps[o], obs["one"], k)
            for m in MODELS2:
                if m in models:
                    e = models[m] - obs[o]
                    per_model[m].append(e[ok])
                    cell[(o, m)] = stat(e[ok])
        best = min(MODELS2, key=lambda m: np.mean([cell[(o, m)]["rms"] for o in ("ab", "ba")]))
        orders.append(best)
        rows.append([key, fmt(order_d["max"]), fmt(stat((obs["one"] - obs["glob"])[ok])["max"]),
                     *[fmt(np.mean([cell[(o, m)]["rms"] for o in ("ab", "ba")])) for m in MODELS2], best])
    if not rows:
        return r.missing("usable pair renders")
    r.add("Two masks over everything, each with one control (job m02). `order` is the largest |dL*| between the two list orders; `one-glob` the "
          "largest difference between one mask holding both sliders and the global panel holding them. The model columns are the RMS error "
          "of each rule against both orders, over the columns where the pair does something: `sum` = one evaluation of the summed sliders (the render of one "
          "mask holding both), `r5` = R5's arithmetic in list order, `seq` = each gain at the level so far, in list order, `gainsum` = the gains added.")
    r.add()
    r.table(["pair", "order max L*", "one-glob max", *MODELS2, "closest"], rows)
    # the same control twice
    rows2 = []
    for item in sorted(d.plan.select(q="Q2", role="pair-twice"), key=lambda i: i.id):
        c, v = item.meta["a"], item.meta["va"]
        two = f"R-q7-full-{c}{masks_plan.fmt(2 * v)}"
        if not d.has(two):
            two = masks_plan.gid("R", [(c, 2 * v)])
        if not d.has(item.id, two):
            continue
        obs = col_median(d, item.id)
        ref = col_median(d, two)
        ok = usable & (np.abs(ref - ch.base_cols) > VISIBLE)
        if c != "E":
            ok &= t.invertible(ref)
        models = _model_set(ch, ch.x, [(c, v), (c, v)], ref, k)
        cell = {m: stat((models[m] - obs)[ok]) for m in MODELS2}
        for m in MODELS2:
            per_model[m].append((models[m] - obs)[ok])
        rows2.append([f"{c}{v:+g} twice", *[f"{fmt(cell[m]['rms'])} / {fmt(cell[m]['max'])}" for m in MODELS2], min(MODELS2, key=lambda m: cell[m]["rms"])])
    if rows2:
        r.add("The same control in two masks, each at v, against one slider at 2v (`sum`): RMS / max |dL*| of each rule:")
        r.add()
        r.table(["case", *MODELS2, "closest"], rows2)
    pooled = {m: sumsq(per_model[m]) for m in MODELS2 if per_model[m]}
    best = min(pooled, key=lambda m: pooled[m]["rms"])
    runner = sorted(pooled, key=lambda m: pooled[m]["rms"])[1]
    settled = pooled[best]["rms"] < 0.5 * pooled[runner]["rms"] or pooled[best]["rms"] < 0.15
    matter = [(key, s["max"]) for key, s in order_diffs if s["max"] is not None and s["max"] > TOL_EQUAL]
    med = float(np.median([s["max"] for _, s in order_diffs if s["max"] is not None]))
    r.add("Pooled over all pairs and both orders: " + ", ".join(f"{m} {fmt(pooled[m]['rms'])} rms / {fmt(pooled[m]['max'])} max" for m in pooled) + ".")
    r.add()
    r.add(f"**List order {'matters' if matter else 'does not matter'}**: " +
          (f"{len(matter)} of {len(order_diffs)} pairs differ by more than {TOL_EQUAL} L* between the two orders (largest {fmt(max(m for _, m in matter))} L*, median {fmt(med)}): " + ", ".join(k for k, _ in matter[:8]) + ("..." if len(matter) > 8 else "") + "."
           if matter else f"no pair differs by more than {TOL_EQUAL} L* between the two orders (largest {fmt(max(s['max'] for _, s in order_diffs))} L*)."))
    cur = pooled["r5"]
    r.add(f"**Lightroom is closest to: {best}{'' if settled else ' (not clearly)'}.** R5's rule (`r5`) has an error of {fmt(cur['rms'])} L* rms, {fmt(cur['p95'])} at p95, {fmt(cur['max'])} at worst over these pairs.")
    if best == "sum":
        r.add("**Rule to adopt:** add the masks' sliders per pixel (each weighted by its coverage and Amount) and evaluate once. That is order-free and equals one mask holding all the sliders; it replaces R5's composition of gains.")
    elif best == "r5":
        r.add("**Rule to adopt:** keep R5's: local gains at the shared base, then global gains in list order, each at the level so far.")
    elif best == "seq":
        r.add("**Rule to adopt:** apply the masks one after another in list order, every gain at the level so far (locals included); R5 sums the locals first.")
    else:
        r.add("**Rule to adopt:** add the gains in stops, independently of the level, in any order.")
    # partial overlap
    pp = _partial_overlap(d, ch, k, r)
    r.verdict = {"best": best, "settled": bool(settled), "pooled": pooled, "order_matters": bool(matter), "order_pairs": [m[0] for m in matter],
                 "order_median_max": med, "current_rule_error": cur, "pairs": len(order_diffs), "partial_overlap": pp}
    return r


def _partial_overlap(d, ch, k, r):
    items = [i for i in d.plan.select(q="PP", role="pp-ab") if d.has(i.id)]
    ga, gb = "R-pp-E+1.5-GA", "R-pp-E+1.5-GB"
    if not items or not d.has(ga, gb) or ch.expo is None:
        return None
    t, usable = ch.tables, ch.usable()
    cover = {}
    for g, id in (("GA", ga), ("GB", gb)):
        cover[g] = np.nan_to_num(row_profile(ch.expo.exposure_of(d.L(id)) / (k * 1.5), usable), nan=0.0)
    rows, per = [], {m: [] for m in ("r5", "slider", "gainsum")}
    for ab in sorted(items, key=lambda i: i.id):
        a, va, ga_, b, vb, gb_ = (ab.meta[x] for x in ("a", "va", "ga", "b", "vb", "gb"))
        key = f"{a}{masks_plan.fmt(va)}-{ga_}_{b}{masks_plan.fmt(vb)}-{gb_}"
        ba_id = ab.id[:-3] + "-ba"
        if not d.has(ba_id):
            continue
        ev = lambda c, v: v * k if c == "E" else v
        la, lb = {a: ev(a, va)}, {b: ev(b, vb)}
        ca, cb = cover[ga_], cover[gb_]
        cell = {}
        both = np.minimum(ca, cb) > 0.02
        for order, (id, layers, cov) in {"ab": (ab.id, [la, lb], [ca, cb]), "ba": (ba_id, [lb, la], [cb, ca])}.items():
            obs = d.L(id)
            preds = {"r5": t.r5_lstar(ch.x[None, :], ch.x[None, :], {}, layers, [c[:, None] for c in cov]),
                     "slider": np.array([t.summed_row({}, layers, [c[i] for c in cov]) for i in range(ch.rows)])}
            preds["gainsum"] = t.T(ch.x[None, :] + sum(c[:, None] * t.gain(next(iter(layer)), next(iter(layer.values())), ch.x)[None, :] for layer, c in zip(layers, cov)))
            single_a = t.L_of_value(a, np.array(va)) if a != "E" else None
            single_b = t.L_of_value(b, np.array(vb)) if b != "E" else None
            ok = usable.copy()
            for single in (single_a, single_b):
                if single is not None:
                    ok &= t.invertible(single)
            mask = both[:, None] & ok[None, :] & (np.abs(preds["r5"] - ch.base_cols[None, :]) > VISIBLE)
            for m in preds:
                cell[(order, m)] = stat((preds[m] - obs)[mask])
                per[m].append((preds[m] - obs)[mask])
        order_d = stat((d.L(ab.id) - d.L(ba_id))[both[:, None] & usable[None, :]])
        best = min(per, key=lambda m: np.mean([cell[(o, m)]["rms"] for o in ("ab", "ba") if cell[(o, m)]["rms"] is not None] or [99]))
        rows.append([key, fmt(order_d["max"]), *[fmt(np.mean([cell[(o, m)]["rms"] for o in ("ab", "ba") if cell[(o, m)]["rms"] is not None] or [None])) for m in per], best])
    if not rows:
        return None
    pooled = {m: sumsq(per[m]) for m in per}
    best = min(pooled, key=lambda m: pooled[m]["rms"])
    r.add()
    r.add("Two gradients that overlap in a band (their coverage from Exposure on the same geometry): RMS of each rule over the overlap band, both orders. "
          "`slider` = per pixel, the coverage-scaled sliders summed and evaluated once.")
    r.add()
    r.table(["pair", "order max L*", *per.keys(), "closest"], rows)
    r.add("Pooled over the overlap band: " + ", ".join(f"{m} {fmt(pooled[m]['rms'])} rms / {fmt(pooled[m]['max'])} max" for m in pooled) + f". **Closest: {best}.**")
    return {"best": best, "pooled": pooled}


# MARK: Q4 the profile of an edge

def flat_alpha(d, ch, id, e):
    """The coverage field of a local-Exposure mask `id` (panel EV `e`) on the flat chart."""
    full_id = f"F-q8-full-E{masks_plan.fmt(e)}"
    return ch.alpha(d.L(id), e, "gain", d.L(full_id) if d.has(full_id) else None)


def binned(position, alpha, lo, hi, width):
    edges = np.arange(lo, hi + width, width)
    idx = np.digitize(position.ravel(), edges) - 1
    ok = (idx >= 0) & (idx < len(edges) - 1) & np.isfinite(alpha.ravel())
    idx, a = idx[ok], alpha.ravel()[ok]
    order = np.argsort(idx, kind="stable")
    idx, a = idx[order], a[order]
    starts = np.searchsorted(idx, np.arange(len(edges)))
    centres, medians = [], []
    for i in range(len(edges) - 1):
        part = a[starts[i]:starts[i + 1]]
        if len(part) >= 4:
            centres.append(0.5 * (edges[i] + edges[i + 1]))
            medians.append(float(np.median(part)))
    return np.array(centres), np.array(medians)


def response_error(ch, e, alpha_a, alpha_b):
    """|dL*| between a flat render at coverage alpha_a and at alpha_b of local Exposure e (the chart's own response)."""
    la = np.interp(np.asarray(alpha_a) * e, ch.expo.e, ch.expo.L[:, 0])
    lb = np.interp(np.asarray(alpha_b) * e, ch.expo.e, ch.expo.L[:, 0])
    return la - lb


def q4(d):
    r = Result("q4", "Q4. The profile of an edge: radial Feather and linear gradients")
    radials = [i for i in d.plan.select(q="Q4", shape="radial") if d.has(i.id) and not i.meta.get("variant") and not i.meta.get("invert") and i.chart == "F"]
    if not d.has("F-base") or not radials:
        return r.missing("the flat chart and the feather masks (job m03)")
    ch = Chart(d, "F")
    if ch.expo is None:
        return r.missing("the flat chart's Exposure series (job m03)")
    rows, cols = ch.rows, ch.cols
    block = d.block
    byf = {}
    for item in radials:
        byf.setdefault(item.meta["feather"], []).append(item)
    table, fits, verdict_radial = [], {}, {}
    ref_e = None
    for f in sorted(byf):
        comp = byf[f][0].masks[0]["CorrectionMasks"][0]
        n, (rx, ry) = mm.radial_n(rows, cols, comp["Left"], comp["Top"], comp["Right"], comp["Bottom"], comp["Angle"])
        alphas = [flat_alpha(d, ch, i.id, i.meta["value"]) for i in byf[f]]
        alpha = np.nanmean(np.array(alphas), axis=0)
        centres, prof = binned(n, alpha, 0.0, 1.7, 0.01)
        fit = mm.fit_edge(centres, prof, lo=0.0, hi=1.7)
        fe = f / 100.0
        r8 = 1 - mm.smoothstep((centres - (1 - fe)) / fe) if fe > 0 else (centres < 1).astype(float)
        e_ref = 2.0 * (float(np.nanmedian(ch.expo.exposure_of(d.L("F-q8-full-E+2")))) / 2.0) if d.has("F-q8-full-E+2") else 2.0
        derr = response_error(ch, e_ref, r8, prof)
        s8 = stat(derr)
        if f == 0:
            lo10 = float(np.interp(0.9, prof[::-1], centres[::-1])) if prof[0] > 0.9 else None
            lo90 = float(np.interp(0.1, prof[::-1], centres[::-1]))
            width_px = (lo90 - lo10) * rx * block if lo10 is not None else None
            n50 = float(np.interp(0.5, prof[::-1], centres[::-1]))
            offset_px = (n50 - 1) * rx * block
            table.append([f"{f}", "hard", f"edge at n = {n50:.3f}", f"width {fmt(width_px, 1)} px (10-90 %, full size)", fmt(float(np.sqrt(np.mean((r8 - prof) ** 2))), 3), f"edge {fmt(offset_px, 1)} px out"])
            verdict_radial[f] = {"width_px": width_px, "offset_px": offset_px, "r8_rms": float(np.sqrt(np.mean((r8 - prof) ** 2)))}
            continue
        best = fit[0]
        fits[f] = best
        table.append([f"{f}", best["family"], f"{best['a']:.3f}", f"{best['b']:.3f}", fmt(best["rms"], 3), fmt(s8["max"])])
        verdict_radial[f] = {"family": best["family"], "a": best["a"], "b": best["b"], "rms": best["rms"],
                             "r8_rms": float(np.sqrt(np.mean((r8 - prof) ** 2))), "r8_dL_p95": s8["p95"], "r8_dL_max": s8["max"],
                             "all": {x["family"]: x["rms"] for x in fit}}
    r.add("Radial gradient, circle of radius 480 px on the flat chart, local Exposure +2 and -2 read against the chart's Exposure series; the coverage is "
          "binned by the normalized radius n (1 on the outline) and fitted by `1 - S((n - a) / (b - a))` for four shapes S. R8's rule is `a = 1 - Feather`, `b = 1`, S = smoothstep "
          "(the feather runs inward from the outline). `R8 dL*` is the largest difference in the picture's L* between R8's coverage and the measured one, at Exposure +2 (for a hard edge, how far outside the outline the edge sits):")
    r.add()
    r.table(["Feather", "best shape", "a (starts falling)", "b (reaches 0)", "fit rms (coverage)", "R8 dL* max"], table)
    form = None
    if fits:
        da = np.mean([fits[f]["a"] - (1 - f / 100) for f in fits])
        db = np.mean([fits[f]["b"] - 1 for f in fits])
        a_s = np.mean([fits[f]["a"] - (1 - f / 200) for f in fits])
        b_s = np.mean([fits[f]["b"] - (1 + f / 200) for f in fits])
        inward = abs(da) < 0.05 and abs(db) < 0.05
        straddle = abs(a_s) < 0.05 and abs(b_s) < 0.05
        form = "inward from the outline (R8)" if inward else ("centred on the outline" if straddle else "neither")
        fam = max(set(x["family"] for x in fits.values()), key=[x["family"] for x in fits.values()].count)
        r.add(f"Mean offsets from R8 (a - (1 - f), b - 1): {da:+.3f}, {db:+.3f}; from a feather centred on the outline: {a_s:+.3f}, {b_s:+.3f}. **The feather runs {form}**; "
              f"the shape most often best is **{fam}**.")
        verdict_radial["form"] = form
        verdict_radial["family"] = fam
        a_fit = np.polyfit([f / 100 for f in fits], [fits[f]["a"] for f in fits], 1)
        b_fit = np.polyfit([f / 100 for f in fits], [fits[f]["b"] for f in fits], 1)
        r.add(f"As functions of the Feather share f: a = {a_fit[1]:.3f} {a_fit[0]:+.3f} f, b = {b_fit[1]:.3f} {b_fit[0]:+.3f} f.")
        verdict_radial["a_fit"], verdict_radial["b_fit"] = a_fit.tolist(), b_fit.tolist()
    r.add()
    # variants: inverted, midpoint, roundness, ellipse, half size
    extra = []
    base_item = next((i for i in radials if i.meta["feather"] == 50), None)
    if base_item:
        comp = base_item.masks[0]["CorrectionMasks"][0]
        base_alpha = np.nanmean([flat_alpha(d, ch, i.id, i.meta["value"]) for i in byf[50]], axis=0)
        for item in d.plan.select(q="Q4", shape="radial"):
            if not d.has(item.id) or item.chart != "F" or not (item.meta.get("variant") or item.meta.get("invert")):
                continue
            a = flat_alpha(d, ch, item.id, item.meta["value"])
            ref = (1 - base_alpha) if item.meta.get("invert") else base_alpha
            extra.append([item.id.replace("F-q4-", ""), fmt(float(np.nanmax(np.abs(a - ref))), 3)])
        for item in d.plan.select(q="Q4", shape="ellipse"):
            if not d.has(item.id):
                continue
            c = item.masks[0]["CorrectionMasks"][0]
            a = flat_alpha(d, ch, item.id, item.meta["value"])
            best = None
            for sign in (1, -1):
                n, _ = mm.radial_n(rows, cols, c["Left"], c["Top"], c["Right"], c["Bottom"], sign * c["Angle"])
                centres, prof = binned(n, a, 0.0, 1.7, 0.01)
                fit = mm.fit_edge(centres, prof, lo=0.0, hi=1.7)[0]
                if best is None or fit["rms"] < best[1]["rms"]:
                    best = (sign, fit)
            extra.append([f"{item.id.replace('F-q4-', '')} (angle {c['Angle']}, read as {'+' if best[0] > 0 else '-'}{c['Angle']})", f"fit rms {fmt(best[1]['rms'], 3)} ({best[1]['family']} a {best[1]['a']:.2f} b {best[1]['b']:.2f})"])
            verdict_radial["angle_sign"] = best[0]
        for item in [i for i in d.plan.select(q="Q4", chart="F2", shape="radial") if d.has(i.id)]:
            a = flat_alpha_half(d, item)
            if a is not None and np.isfinite(a).any():
                n_small, _ = mm.radial_n(a.shape[0], a.shape[1], comp["Left"], comp["Top"], comp["Right"], comp["Bottom"], 0)
                c1, p1 = binned(n_small, a, 0.0, 1.7, 0.02)
                n_big, _ = mm.radial_n(rows, cols, comp["Left"], comp["Top"], comp["Right"], comp["Bottom"], 0)
                c2, p2 = binned(n_big, base_alpha, 0.0, 1.7, 0.02)
                m = min(len(p1), len(p2))
                extra.append(["half-size chart, same box and Feather 50", f"max |coverage - full-size| = {fmt(float(np.max(np.abs(p1[:m] - p2[:m]))), 3)}"])
                verdict_radial["resolution"] = float(np.max(np.abs(p1[:m] - p2[:m])))
                break
    if extra:
        r.add("Variants (largest difference in coverage from the plain Feather 50 radial; the inverted one is compared with 1 - coverage):")
        r.add()
        r.table(["item", "difference"], extra)
    # linear gradients
    lin, lverdict = [], {}
    fits_lin = {}
    for geom in ("GV", "GS", "GH", "GD"):
        items = [i for i in d.plan.select(q="Q4", shape="linear", geom=geom) if d.has(i.id) and i.chart == "F"]
        if not items:
            continue
        full, zero = masks_plan.GEOM[geom]
        alpha = np.nanmean([flat_alpha(d, ch, i.id, i.meta["value"]) for i in items], axis=0)
        best_space = None
        for pixel_space in (True, False):
            t = mm.gradient_t(rows, cols, full, zero, pixel_space)
            centres, prof = binned(t, alpha, -0.6, 1.6, 0.01)
            fit = mm.fit_edge(centres, prof, lo=-0.6, hi=1.6)[0]
            if best_space is None or fit["rms"] < best_space[2]["rms"]:
                best_space = (pixel_space, (centres, prof), fit)
        pixel_space, (centres, prof), fit = best_space
        fits_lin[geom] = fit
        s8 = stat(response_error(ch, 1.0, 1 - mm.smoothstep(centres), prof))
        at = [float(np.interp(t_, centres, prof)) for t_ in (0.1, 0.25, 0.5, 0.75, 0.9)]
        lin.append([geom, "pixels" if pixel_space else "normalized", fit["family"], f"{fit['a']:.3f}", f"{fit['b']:.3f}", fmt(fit["rms"], 3)] + [fmt(x, 3) for x in at] + [fmt(s8["max"])])
        lverdict[geom] = {"space": "pixels" if pixel_space else "normalized", **{k: fit[k] for k in ("family", "a", "b", "rms")}, "at": at, "r8_dL_max": s8["max"], "all": None}
    if lin:
        r.add("Linear gradients on the flat chart (Exposure +1, +-2 read against the series), fitted by `1 - S((t - a) / (b - a))`, t = 0 at the Full point and 1 at the Zero point. "
              "R8's rule is a = 0, b = 1, smoothstep. The last columns are the coverage at t = 0.1, 0.25, 0.5, 0.75, 0.9; `space` is how t is measured, which matters for the diagonal gradient:")
        r.add()
        r.table(["gradient", "space", "best shape", "a", "b", "fit rms", "0.1", "0.25", "0.5", "0.75", "0.9", "R8 dL* max"], lin)
        vgv = lverdict.get("GV")
        if vgv:
            r.add(f"**The linear gradient's profile is {vgv['family']} from t = {vgv['a']:.3f} to {vgv['b']:.3f}** (R8: smoothstep from 0 to 1); R8's rule is off by at most {fmt(vgv['r8_dL_max'])} L* at Exposure +1.")
        if "GD" in lverdict:
            r.add(f"The diagonal gradient's isolines are measured in **{lverdict['GD']['space']}**" +
                  (" (perpendicular to the line on the picture, as `MaskSpace`'s long-side units assume)." if lverdict["GD"]["space"] == "pixels" else " (a skewed profile on a wide picture: Argent must use the picture's normalized axes)."))
        r.add()
    r.verdict = {"radial": verdict_radial, "linear": lverdict}
    return r


def flat_alpha_half(d, item):
    ch2 = Chart(d, "F2")
    if ch2.expo is None:
        return None
    k = 1.0
    if d.has("F-base", "F-q8-full-E+2"):
        ch = Chart(d, "F")
        k = float(np.nanmedian(ch.expo.exposure_of(d.L("F-q8-full-E+2")))) / 2.0
    return ch2.alpha(d.L(item.id), item.meta["value"], "gain", None, k)


# MARK: Q5 the algebra of components

def q5(d):
    r = Result("q5", "Q5. Add, Subtract, Intersect and Invert of crossing gradients")
    need = ["F-base", "F-q4-GV-E+1", "F-q4-GH-E+1", "F-q5-C", "F-q5-A+B"]
    if not d.has(*need):
        return r.missing("the flat chart and the algebra masks (job m03)")
    ch = Chart(d, "F")
    if ch.expo is None:
        return r.missing("the flat chart's Exposure series (job m03)")
    full_id = "F-q8-full-E+1"
    full = d.L(full_id) if d.has(full_id) else None
    alpha = lambda id: ch.alpha(d.L(id), 1, "gain", full)
    a, b, c = alpha("F-q4-GV-E+1"), alpha("F-q4-GH-E+1"), alpha("F-q5-C")
    e1 = float(np.nanmedian(ch.expo.exposure_of(full))) if full is not None else 1.0
    T = lambda F: {
        "A+B": F["add"](a, b), "B+A": F["add"](b, a), "A-B": F["sub"](a, b), "B-A": F["sub"](b, a),
        "AxB": F["int"](a, b), "BxA": F["int"](b, a), "invA": 1 - a,
        "A+invB": F["add"](a, 1 - b), "invA+invB": F["add"](1 - a, 1 - b), "invAxB": F["int"](1 - a, b),
        "A+B+C": F["add"](F["add"](a, b), c)}
    families = {name: T(F) for name, F in mm.ALGEBRAS.items()}
    names = list(next(iter(families.values())))
    rows, totals = [], {f: [] for f in families}
    for name in names:
        id = f"F-q5-{name}"
        if not d.has(id):
            continue
        obs = alpha(id)
        cells = []
        for f in families:
            pred = families[f][name]
            ok = np.isfinite(obs) & np.isfinite(pred)
            diff = (pred - obs)[ok]
            totals[f].append(diff)
            dl = response_error(ch, e1, np.clip(pred[ok], 0, 1), np.clip(obs[ok], 0, 1))
            cells.append(f"{fmt(float(np.sqrt(np.mean(diff ** 2))), 3)} / {fmt(float(np.max(np.abs(dl))))}")
        errs = [float(np.sqrt(np.mean(((families[f][name] - obs)[np.isfinite(obs) & np.isfinite(families[f][name])]) ** 2))) for f in families]
        rows.append([name, *cells, list(families)[int(np.argmin(errs))]])
    r.add("Two gradients (A down the frame, B across it) and a radial C, combined in one mask with local Exposure +1; the coverage of each combination is read against the "
          "flat Exposure series. Each cell is the RMS error in coverage / the largest error in the picture's L* of one algebra (`prob` = R8's `c + v - c v`, `c (1 - v)`, `c v`; "
          "`minmax` = max, `min(c, 1 - v)`, min; `luk` = clamped sum, `max(0, c - v)`, `max(0, c + v - 1)`). Intersect is Subtract of the inverted component in all three:")
    r.add()
    r.table(["combination", *[f"{f} rms / L* max" for f in families], "closest"], rows)
    pooled = {f: sumsq(totals[f]) for f in families}
    best = min(pooled, key=lambda f: pooled[f]["rms"])
    runner = sorted(pooled, key=lambda f: pooled[f]["rms"])[1]
    settled = pooled[best]["rms"] < 0.5 * pooled[runner]["rms"] or pooled[best]["rms"] < 0.02
    comm = None
    if d.has("F-q5-A+B", "F-q5-B+A"):
        comm = float(np.nanmax(np.abs(alpha("F-q5-A+B") - alpha("F-q5-B+A"))))
    r.add("Pooled: " + ", ".join(f"{f} {fmt(pooled[f]['rms'], 3)} rms (max {fmt(pooled[f]['max'], 3)})" for f in pooled) + f". Add is {'commutative' if comm is not None and comm < 0.02 else 'not commutative'} (A+B against B+A: {fmt(comm, 3)}).")
    prob = pooled["prob"]
    worst_dl = max(float(np.max(np.abs(response_error(ch, e1, np.clip(families['prob'][n][np.isfinite(alpha(f'F-q5-{n}'))], 0, 1), np.clip(alpha(f'F-q5-{n}')[np.isfinite(alpha(f'F-q5-{n}'))], 0, 1))))) for n in names if d.has(f"F-q5-{n}"))
    r.add(f"**Lightroom's algebra is closest to: {best}{'' if settled else ' (not clearly)'}.** R8's (`prob`) error: {fmt(prob['rms'], 3)} in coverage rms, {fmt(prob['max'], 3)} at worst, {fmt(worst_dl)} L* at worst at Exposure +1. " +
          ("**Keep R8's.**" if best == "prob" else f"**Rule to adopt:** the `{best}` algebra: " + {"minmax": "Add = max, Subtract = min(c, 1 - v), Intersect = min (a crease in the gradient where the two meet; R8 measured a slope jump of 1.1).", "luk": "Add = min(1, c + v), Subtract = max(0, c - v), Intersect = max(0, c + v - 1)."}[best]))
    r.verdict = {"algebra": best, "settled": bool(settled), "pooled": pooled, "commutative": comm is not None and comm < 0.02, "r8_error": prob, "r8_dL_max": worst_dl}
    return r


# MARK: Q6 the base

def q6(d):
    r = Result("q6", "Q6. Does a mask's Highlights and Shadows read the same base as the global ones?")
    r.verdict = {}
    got = False
    if d.has("L-base"):
        base = d.L("L-base")
        rows_, cols_ = base.shape
        scale = cols_ * d.block / 3000
        _, layout = masks_plan.make_charts.locality(scale)
        out = []
        worst = {}
        for item in sorted(d.plan.select(q="Q6", chart="L"), key=lambda i: i.id):
            if "edge" not in item.meta or not d.has(item.id):
                continue
            c, v, size = item.meta["ctrl"], item.meta["value"], item.meta["edge"]
            gid = masks_plan.gid("L", [(c, v)])
            if not d.has(gid):
                continue
            mask, glob = d.L(item.id), d.L(gid)
            effect = np.abs(glob - base)
            xc = item.meta["edge_x"] * cols_
            nominal = size if scale == 1.0 else max(2, round(size * scale))
            for sq in layout["squares"]:
                if sq["size"] != nominal:
                    continue
                x0, y0, x1, y1 = (int(round(z / d.block)) for z in sq["box"])
                margin = max(2, int(round(12 * scale / d.block)))
                xe = int(xc) - margin
                if xe <= x0 + 1:
                    continue
                pad = int(round(sq["size"] * 0.5 / d.block))
                ya, yb = max(0, y0 - pad), min(rows_, y1 + pad)
                xa = max(0, x0 - pad)
                region = (slice(ya, yb), slice(xa, xe))
                dd = np.abs(mask[region] - glob[region])
                out.append([f"{c}{v:+g}", f"{size}", sq["row"], fmt(float(effect[region].max())), fmt(float(dd.mean()), 3), fmt(float(dd.max()))])
                key = (c, v)
                worst[key] = max(worst.get(key, 0.0), float(dd.max()))
        full = []
        for item in d.plan.select(q="Q6", chart="L", role="mask"):
            if "edge" in item.meta or not d.has(item.id):
                continue
            gid = masks_plan.gid("L", [(item.meta["ctrl"], item.meta["value"])])
            if d.has(gid):
                full.append(float(np.max(np.abs(d.L(item.id) - d.L(gid)))))
        if out:
            got = True
            r.add("Locality chart (squares on dark, mid and bright surrounds): a mask that covers the left of a hard vertical edge through the middle of the 512- and 64-pixel squares, against the "
                  "global control. Compared inside the mask (12 px or more from the edge at full size), over the square and the same again around it:")
            r.add()
            r.table(["control", "square px", "band", "global effect max L*", "mean |mask - global|", "max |mask - global|"], out)
            if full:
                r.add(f"A mask over the whole chart against the global control: at most {fmt(max(full))} L*.")
            w = max(worst.values())
            shared = w <= max(TOL_EQUAL, 0.05 * 10)
            r.add(f"**{'The mask reads the same base as the global control' if shared else 'The mask does NOT read the global base'}**: inside the mask, near an edge, the largest difference from the global control is {fmt(w)} L*.")
            r.verdict["base_shared"] = bool(shared)
            r.verdict["edge_max_diff"] = w
    adapt = {}
    for chart in ("AD", "AB"):
        if d.has(f"{chart}-base"):
            adapt[chart] = True
    if len(adapt) == 2:
        scale = d.L("AD-base").shape[1] * d.block / 3000
        _, layout = masks_plan.make_charts.adaptation("dark", scale)
        r0, r1 = (int(z / d.block) for z in layout["ramp"]["measure"])
        win = lambda id: np.median(d.L(id)[r0:r1], axis=0)
        rows3 = []
        verdict3 = {}
        for c, v in (("H", -100), ("S", 100)):
            ids = {(kind, ch): (masks_plan.gid(ch, [(c, v)]) if kind == "glob" else f"{ch}-q6-{kind}-{c}{masks_plan.fmt(v)}") for kind in ("glob", "band", "full") for ch in ("AD", "AB")}
            if not d.has(*ids.values()):
                continue
            g_ad, g_ab = win(ids[("glob", "AD")]), win(ids[("glob", "AB")])
            b_ad, b_ab = win(ids[("band", "AD")]), win(ids[("band", "AB")])
            f_ad, f_ab = win(ids[("full", "AD")]), win(ids[("full", "AB")])
            dg = float(np.max(np.abs(g_ad - g_ab)))
            db = float(np.max(np.abs(b_ad - b_ab)))
            same = float(max(np.max(np.abs(b_ad - g_ad)), np.max(np.abs(b_ab - g_ab))))
            rows3.append([f"{c}{v:+g}", fmt(dg), fmt(db), fmt(same), fmt(float(max(np.max(np.abs(f_ad - g_ad)), np.max(np.abs(f_ab - g_ab)))))])
            verdict3[f"{c}{v:+g}"] = {"global_content_dependence": dg, "band_content_dependence": db, "band_vs_global": same}
        if rows3:
            got = True
            r.add("The ramp band of the dark-content and bright-content adaptation charts (rows 30-200 of 2000), where Lightroom's Highlights and Shadows are known to depend on the "
                  "rest of the frame; the mask covers only the ramp band, far from the content below it:")
            r.add()
            r.table(["control", "global: dark vs bright content (max L*)", "band mask: dark vs bright (max L*)", "band mask vs global, same content", "mask over everything vs global"], rows3)
            dgs = [v["global_content_dependence"] for v in verdict3.values()]
            dbs = [v["band_content_dependence"] for v in verdict3.values()]
            if max(dgs) > 1.0:
                ratio = max(dbs) / max(dgs)
                kind = "frame-wide statistics, like the global control" if ratio >= 0.7 else ("its own masked region's statistics" if ratio <= 0.3 else "partly the frame's and partly its own")
                r.add(f"The global control's ramp moves {fmt(max(dgs))} L* with the content below; the band mask's moves {fmt(max(dbs))} L*: **the mask adapts to {kind}.**")
                r.verdict["adaptation"] = "frame" if ratio >= 0.7 else ("region" if ratio <= 0.3 else "partial")
            else:
                r.add("The global control hardly depends on the content here (under 1 L*), so these charts cannot show where the mask's adaptation comes from.")
                r.verdict["adaptation"] = "inconclusive"
            r.verdict["adaptation_detail"] = verdict3
    if not got:
        return r.missing("the locality and adaptation charts (job m04)")
    r.add()
    if "base_shared" in r.verdict:
        r.add("R5 chose one shared base from the unadjusted frame for the panel and every mask (a base per mask was rejected); " +
              ("the data agree." if r.verdict["base_shared"] else f"the data disagree by up to {fmt(r.verdict['edge_max_diff'])} L* near a mask's edge."))
    return r


# MARK: Checking the session, summarising, running everything

QUESTIONS = ["q1", "q2", "q3", "q4", "q5", "q6", "q7", "q8"]


def check(d, allow_scaled=False):
    """Completeness of the exports, what the plug-in logged, the noise floor and the throughput. Returns (lines, ok).
    The charts' sizes must be the charts' own unless allow_scaled (synthetic tests render them small)."""
    lines, ok = [], True
    lines.append("## Session check")
    lines.append("")
    rows = []
    for job in d.plan.jobs:
        have = [i for i in job.items if d.path(i.id) is not None]
        rows.append([job.name, len(job.items), len(have), "ok" if len(have) == len(job.items) else ("not run" if not have else f"{len(job.items) - len(have)} missing")])
        if have and len(have) != len(job.items):
            ok = False
    lines.append("| job | items | exports found | state |")
    lines.append("| --- | --- | --- | --- |")
    lines += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    lines.append("")
    for kind in ("ERROR", "WARN"):
        found = d.done_lines(kind)
        if found:
            ok = False if kind == "ERROR" else ok
            lines.append(f"**{kind} lines from the plug-in ({len(found)}):**")
            lines += [f"- {l}" for l in found[:12]] + ([f"- ... {len(found) - 12} more"] if len(found) > 12 else [])
            lines.append("")
    notes = d.done_lines("NOTE")
    if notes:
        lines.append(f"**NOTE lines (fields Lightroom changed or dropped on reading a table back), {len(notes)}:**")
        lines += [f"- {l}" for l in notes[:12]] + ([f"- ... {len(notes) - 12} more"] if len(notes) > 12 else [])
        lines.append("")
    # sizes
    bad = []
    shapes = {}
    for item in d.plan.items.values():
        if d.path(item.id) is None or item.chart not in ("R", "F"):
            continue
        h, w = d.L(item.id).shape
        shapes.setdefault(item.chart, set()).add((h, w))
        want = {"R": masks_plan.make_charts.MASK_RAMP, "F": masks_plan.make_charts.MASK_FLAT}[item.chart]
        if not allow_scaled and (abs(w * d.block - want[0]) > d.block or abs(h * d.block - want[1]) > d.block):
            bad.append(f"{item.id}: {w * d.block}x{h * d.block}, expected {want[0]}x{want[1]}")
    for chart, found in shapes.items():
        if len(found) > 1:
            bad.append(f"chart {chart}: exports of different sizes {sorted(found)[:3]}")
    if bad:
        ok = False
        lines.append("**Exports with the wrong size:** " + "; ".join(bad[:5]))
        lines.append("")
    # timing
    planned = d.plan.estimate()
    seconds, items = 0.0, 0
    for job in d.plan.jobs:
        t = d.root / f"exports-{job.name}" / "timing.tsv"
        if t.exists():
            for line in t.read_text().splitlines():
                parts = line.split("\t")
                if parts[0] == "total":
                    seconds += float(parts[1])
                    items += int(parts[2])
    if items:
        lines.append(f"**Throughput:** {items} items in {seconds / 60:.1f} min of Lightroom time ({seconds / items:.2f} s an item); the plan expected {planned['run_min']:.1f} min for all {sum(len(j.items) for j in d.plan.jobs)}.")
        lines.append("")
    # smoke: the three ways to cover the frame
    if d.has("R-gE+1"):
        ref = d.L("R-gE+1")
        for kind in ("grad", "far", "lum", "rad"):
            id = f"R-smoke-{kind}-E+1"
            if d.has(id):
                lines.append(f"- smoke, a mask over everything ({kind}) against global Exposure +1: largest difference {np.max(np.abs(d.L(id) - ref)):.2f} L*")
        lines.append("")
    lines.append("**Verdict: " + ("the exports are complete and clean; run `analyze_masks.py all`." if ok else "something above needs a look before the numbers are trusted.") + "**")
    return lines, ok


def _line(key, lightroom, candidate, decision, error):
    return [key, lightroom, candidate, decision, error]


def summarize(res):
    """One row per question: what Lightroom does, Argent's candidate, the decision, the cost of keeping the current rule."""
    rows = []

    def ok(q):
        return q in res and res[q].status == "ok" and res[q].verdict

    if ok("q1"):
        v = res["q1"].verdict
        cur = v["current_rule_error"]
        rows.append(_line("Q1 partial coverage", f"scales the {v['law']}" + ("" if v["settled"] else " (unclear)"), "gain in stops (R5)",
                          "KEEP" if v["law"] == "gain" else ("CHANGE to per-pixel slider scaling" if v["law"] == "slider" else "DECIDE"),
                          f"{fmt(cur['rms'])} rms / {fmt(cur['max'])} max L*"))
    if ok("q2"):
        v = res["q2"].verdict
        cur = v["current_rule_error"]
        rows.append(_line("Q2 overlap", f"closest to `{v['best']}`; list order {'matters' if v['order_matters'] else 'does not matter'}", "R5: locals summed at the base, globals in list order",
                          "KEEP" if v["best"] == "r5" else f"CHANGE to `{v['best']}`", f"{fmt(cur['rms'])} rms / {fmt(cur['max'])} max L*"))
    if ok("q3"):
        v = res["q3"].verdict
        cur = v.get("current_rule_error") or {}
        rows.append(_line("Q3 Amount", f"scales the {v['best']}{'' if v['settled'] else ' (unclear)'}; linear to {v['linear_to']:g}" + (f", clamped at {fmt(v['clamp'])}" if v.get("clamp") is not None else ""),
                          "slider (tables at Amount x V)", "KEEP" if v["best"] == "slider" else "CHANGE to scaling the " + str(v["best"]),
                          f"{fmt(cur.get('rms'))} rms / {fmt(cur.get('max'))} max L*"))
    if ok("q4"):
        v = res["q4"].verdict
        rad, lin = v["radial"], v["linear"]
        gv = lin.get("GV")
        form = rad.get("form")
        worst = max([x["r8_dL_max"] for k, x in rad.items() if isinstance(k, int) and x.get("r8_dL_max") is not None] + ([gv["r8_dL_max"]] if gv else [0]))
        keep = form and "inward" in form and rad.get("family") == "smoothstep" and gv and gv["family"] == "smoothstep" and abs(gv["a"]) < 0.05 and abs(gv["b"] - 1) < 0.05
        rows.append(_line("Q4 feather profile", f"radial: {form}, {rad.get('family')}; linear: {gv['family'] if gv else 'n/a'} from {fmt(gv['a'] if gv else None, 2)} to {fmt(gv['b'] if gv else None, 2)}",
                          "smoothstep, feather inward from the outline (R8)", "KEEP" if keep else "CHANGE constants (table in Q4)", f"{fmt(worst)} L* max at Exposure +-1 to +-2"))
    if ok("q5"):
        v = res["q5"].verdict
        rows.append(_line("Q5 component algebra", f"closest to `{v['algebra']}`", "`c + v - c v`, `c (1 - v)`, `c v` (R8)",
                          "KEEP" if v["algebra"] == "prob" else f"CHANGE to `{v['algebra']}`", f"{fmt(v['r8_error']['rms'], 3)} rms coverage; {fmt(v['r8_dL_max'])} L* max at Exposure +1"))
    if ok("q6"):
        v = res["q6"].verdict
        shared = v.get("base_shared")
        rows.append(_line("Q6 the base", ("shared with the global" if shared else "not the global base") if shared is not None else "n/a (locality chart not run)",
                          "one shared base (R5)", ("KEEP" if shared else "CHANGE") if shared is not None else "n/a",
                          f"{fmt(v.get('edge_max_diff'))} L* near an edge; adaptation: {v.get('adaptation', 'n/a')}"))
    if ok("q7"):
        v = res["q7"].verdict
        rows.append(_line("Q7 local with global", f"a mask over everything {'equals' if v['equal'] else 'does NOT equal'} the control ({fmt(v['max_diff'])} L* worst); with the panel closest to `{v['order']}`",
                          "equal; the panel first (R5)", ("KEEP" if v["equal"] and v["order"] in (None, "panel-first") else "CHANGE (see Q7)"),
                          f"{fmt(v['r5_pooled']['rms']) if v.get('r5_pooled') else 'n/a'} rms L* (R5, panel first, against the panel + mask renders)"))
    if ok("q8"):
        v = res["q8"].verdict
        sc = v["exposure_scale"]
        clip = ", ".join(f"{'+' if s > 0 else '-'}{abs(c['stored']):g} stored ({fmt(abs(c['stops']), 1)} stops)" for s, c in ((1, v["clip_pos"]), (-1, v["clip_neg"])) if c)
        rows.append(_line("Q8 ranges", f"stored x {fmt(4 * sc if sc else None, 2)} = EV; clamp {clip or 'none seen'}", "+-4 EV, stored EV/4",
                          "KEEP" if sc is not None and abs(sc - 1) < 0.03 else "CHANGE", f"scale {fmt(sc, 3)} of the plan's"))
    return rows


def run_all(d, only=None):
    res = {}
    q1res = None
    for q in QUESTIONS:
        if only and q not in only:
            continue
        if q == "q1":
            res[q] = q1res = q1(d)
        elif q in ("q2", "q3"):
            res[q] = globals()[q](d, q1res or (q1(d) if "q1" not in res else res["q1"]))
        else:
            res[q] = globals()[q](d)
    return res


def write_report(res, d, out, plan, check_lines, started):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    rows = summarize(res)
    lines = ["# What the mask session found", "", f"Plan: {sum(len(j.items) for j in plan.jobs)} items in {len(plan.jobs)} jobs; analysed {started}. Exports read from `{d.root}`. "
             f"L* is CIE L* of the export's linear luminance, averaged over {d.block} x {d.block} blocks. The method's own floor, on a world with known laws, is about 0.1 L* (interpolation of the Exposure series).", "",
             "## One page", ""]
    lines.append("| question | Lightroom | Argent's candidate | decision | error of keeping the current rule |")
    lines.append("| --- | --- | --- | --- | --- |")
    lines += ["| " + " | ".join(r) + " |" for r in rows]
    lines.append("")
    missing = [q for q in QUESTIONS if q in res and res[q].status != "ok"]
    if missing:
        lines.append("Not answered (data missing): " + ", ".join(missing) + ".")
        lines.append("")
    lines += check_lines
    lines.append("")
    for q in QUESTIONS:
        if q in res:
            lines.append(res[q].markdown())
            lines.append("")
    (out / "REPORT.md").write_text("\n".join(lines))

    def clean(x):
        if isinstance(x, dict):
            return {str(k): clean(v) for k, v in x.items()}
        if isinstance(x, (list, tuple)):
            return [clean(v) for v in x]
        if isinstance(x, (np.floating, np.integer)):
            return None if isinstance(x, np.floating) and not np.isfinite(x) else x.item()
        if isinstance(x, float) and not math.isfinite(x):
            return None
        if isinstance(x, np.ndarray):
            return clean(x.tolist())
        return x
    (out / "results.json").write_text(json.dumps({q: {"status": r.status, "verdict": clean(r.verdict)} for q, r in res.items()}, indent=1))
    return out / "REPORT.md"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["check", "all", *QUESTIONS])
    parser.add_argument("--root", default=str(probe.DATA), help="the folder with masks-plan.json and the exports-<job>/ folders")
    parser.add_argument("--out", help="where the report goes (default ROOT/masks-report)")
    parser.add_argument("--block", type=int, default=BLOCK)
    parser.add_argument("--jobs", help="the folder of the plug-in's .done logs (default ROOT/jobs)")
    parser.add_argument("--scaled", action="store_true", help="accept exports smaller than the charts (synthetic tests)")
    args = parser.parse_args()
    root = Path(args.root)
    plan_path = root / "masks-plan.json"
    if not plan_path.exists():
        raise SystemExit(f"{plan_path} is missing: run jobs.py masks first")
    plan = masks_plan.load_plan(plan_path)
    out = Path(args.out) if args.out else root / "masks-report"
    d = Data(plan, root, extra=[args.jobs] if args.jobs else [], block=args.block, cache=out / "cache")
    if args.command == "check":
        lines, ok = check(d, args.scaled)
        print("\n".join(lines))
        sys.exit(0 if ok else 1)
    only = None if args.command == "all" else [args.command]
    res = run_all(d, only)
    if args.command != "all":
        print(res[args.command].markdown())
        return
    lines, _ = check(d, args.scaled)
    path = write_report(res, d, out, plan, lines, "now")
    print(path.read_text().split("## Session check")[0])
    print(f"full report: {path}")


if __name__ == "__main__":
    main()
