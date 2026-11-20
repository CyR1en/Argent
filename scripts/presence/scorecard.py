"""The Presence scorecard: one command that judges a release argent-spike against every pass bar of
docs/presence-plan.md section 2, through the fit scripts' own scorers, so that no bar is computed two ways.

    .venv/bin/python -I scripts/presence/scorecard.py [--binary PATH | --stand-in] [--slider S ...]
                                                     [--subset full|quick] [--out DIR]

It prints every bar with its measured value, its limit and its result, and writes scorecard.json and scorecard.md in
DIR (default: this checkout's .build/presence-scorecard/SUBSET). Exit 0 when every bar ran and passed, 1 when a bar
failed or could not be scored, 3 when nothing failed but a bar was not judged: its stage is not built, its limit is
pending, or a quick subset measured part of it or none of it. Every bar of each slider's list is reported once, so a
full run whose scorer returned no score for a bar, or a score over part of its runs, fails on that bar, and a quick
run never exits 0.

Where the bars come from (E is the program's evidence folder):

- Identity, each slider: the flag at 0 prints the same array, bit for bit, as no flag, on the probe raw with the
  app's automatic print (--auto --no-lens), on Portra 400 and Ektar 100. Measured here, since it reads no fit.
- Dehaze: E/validate/dehaze/bars.json through `fit_dehaze.score_spike` (fidelity, each frame, parity, identity),
  and F2's stability bar (E/fit/dehaze/report.md section 10, with Ektar 100's limit at -100 from the prototype's
  own score) through `fit_dehaze.stability_rows`, its limits in `fit_dehaze.STABILITY_MAX`.
- Saturation and Vibrance: E/validate/colour/bars.json through `fit_colour.score_build` and `fit_colour.judge`.
- Clarity and Texture: E/validate/detail/bars.json through `fit_clarity_round2.score_spike` and `judge_spike`, the
  build and F1's prototype both under the explicit aim (no tone step), with the parity limits.

Before a slider's bars render anything, one quarter-size render with the slider at 50 asks the build whether the
stage exists. A build without it stops with the piece and the package that builds it, and every bar of that slider
is reported as not built with that line.

--stand-in scores `stand_in.py` in place of a build: the main checkout's spike with each fit's prototype stage behind
its flag, which must meet the bars the prototypes met.
"""
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass, replace
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
CHECKOUT = HERE.parents[1]
sys.path.insert(0, str(HERE.parent / "lightroom-probe"))
sys.path.insert(0, str(HERE))
import fit_clarity_round2 as R  # noqa: E402
import fit_colour as C  # noqa: E402
import fit_dehaze as D  # noqa: E402
import probe  # noqa: E402
import stand_in  # noqa: E402

# Presence.Control.allCases, whose rawValue is each flag's name.
SLIDERS = ("texture", "clarity", "dehaze", "vibrance", "saturation")
# Portra 400 and Ektar 100, the two stocks every fit scored.
STOCKS = ("kodak-portra-400", "kodak-ektar-100")
PROBE_RAW = R.F.PROBE_RAW
IDENTITY_FLAGS = ("--auto", "--no-lens")

PASS, FAIL, NOT_BUILT, PENDING, SUBSET, NOT_MEASURED, ERROR = (
    "pass", "fail", "not built", "pending", "subset", "not measured", "error")


@dataclass(frozen=True)
class Row:
    """One bar: what it measures, the measured value (None until scored), its limit (None while the limit is
    pending), and its result."""
    slider: str
    bar: str
    stock: str
    measured: float | None = None
    limit: float | None = None
    status: str = PENDING
    note: str = ""


def judged(ok):
    return PASS if ok else FAIL


@dataclass(frozen=True)
class Subset:
    """The frames each scorer renders; None is every frame its bars name."""
    dehaze: list | None = None
    parity: list | None = None
    stability: list | None = None
    colour: list | None = None
    colour_stocks: list | None = None
    detail: list | None = None


SUBSETS = {
    "full": Subset(),
    "quick": Subset(dehaze=["r-photo-fog-woods"], parity=["r-photo-fog-woods"], stability=["p-raw"],
                    colour=["r-photo-horizon"], colour_stocks=list(STOCKS), detail=["p-photo-hazy"]),
}


# MARK: Asking the build whether a stage exists

def stage(binary, slider):
    """(None, "") when the build renders --SLIDER 50; (NOT_BUILT, the build's own line naming the piece and its
    package) when the stage is not built yet; (ERROR, its output) when the render fails another way."""
    with tempfile.TemporaryDirectory() as out:
        run = subprocess.run([str(binary), str(PROBE_RAW), "--stock", str(D.STOCKS / STOCKS[0]), "--out", out,
                              "--no-warmup", "--no-lens", "--scale", "0.25", f"--{slider}", "50",
                              "--print-out", str(Path(out) / "print.npy")], capture_output=True, text=True)
    if run.returncode == 0:
        return None, ""
    text = (run.stderr + run.stdout).strip()
    line = next((l.removeprefix("error: ") for l in text.splitlines() if "is not built yet" in l), None)
    return (NOT_BUILT, line) if line else (ERROR, f"--{slider} 50 failed (exit {run.returncode}): {text[-1500:]}")


# MARK: Identity

def print_file(binary, stock, extra, folder):
    folder.mkdir(parents=True, exist_ok=True)
    probe.spike(PROBE_RAW, folder, D.STOCKS / stock, *IDENTITY_FLAGS, *extra, "--print-out", folder / "print.npy",
                binary=binary)
    return folder / "print.npy"


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""):
            h.update(chunk)
    return h.hexdigest()


def identity_rows(binary, sliders, work, log):
    """Each flag at 0 against no flag, on the probe raw at full size with the app's automatic print, on each stock:
    the print arrays bit for bit. The measured value is how many of the print's values differ."""
    rows = []
    for stock in STOCKS:
        with tempfile.TemporaryDirectory(dir=work) as folder:
            base = print_file(binary, stock, [], Path(folder) / "base")
            base_digest = digest(base)
            for s in sliders:
                zero = print_file(binary, stock, [f"--{s}", "0"], Path(folder) / s)
                differing = 0 if digest(zero) == base_digest else int(np.count_nonzero(
                    np.load(zero, mmap_mode="r") != np.load(base, mmap_mode="r")))
                zero.unlink()
                rows.append(Row(s, f"identity: --{s} 0 prints what no flag prints, bit for bit", stock,
                                float(differing), 0.0, judged(differing == 0), "values that differ"))
                log(f"  identity --{s} 0 on {stock}: {differing} values differ")
    return rows


# MARK: Dehaze: V2's bars and F2's stability

def dehaze_bars(sliders):
    bars = json.loads(D.BARS.read_text())
    rows = []
    for stock in bars["stocks"]:
        rows += [Row("dehaze", f"fidelity, mean {m}", stock, limit=b["max"]) for m, b in bars["fidelity"][stock].items()]
        rows += [Row("dehaze", f"frame {j}, change", stock, limit=b["max"]) for j, b in bars["perFrame"][stock].items()]
        rows += [Row("dehaze", f"parity {j} {v:+d}", stock, limit=bars["parity"]["meanMax"])
                 for j in bars["parity"]["frames"] for v in bars["parity"]["values"]]
        rows += [Row("dehaze", f"stability {j} {v:+d}", stock, limit=m)
                 for j in D.STABILITY_FRAMES for v, m in D.STABILITY_MAX[stock].items()]
    return rows + [Row("dehaze", f"identity {bars['identity']['frame']} at 0", bars["stocks"][0], limit=0.0)]


def dehaze_scores(binary, sliders, subset, work, log):
    bars = json.loads(D.BARS.read_text())
    if subset.parity is not None:
        bars = {**bars, "parity": {**bars["parity"], "frames": subset.parity}}
    rows = D.score_spike(binary, bars, subset.dehaze, parity=True, log=log)
    rows += D.stability_rows(binary, bars, subset.stability or D.STABILITY_FRAMES, log)
    out = []
    for r in rows:
        note = (f"p99 {r['p99']:.3f} <= {r['p99Max']}" if "p99Max" in r else f"p99 {r['p99']:.3f}" if "p99" in r
                else f"prototype {r['prototype']:.3f}" if "prototype" in r else "")
        if "frames" in r:
            note += f", {r['frames']} of {len(bars['frames'])} frames"
        out.append(Row("dehaze", r["bar"], r["stock"], r["measured"], r["max"],
                       SUBSET if r["pass"] is None else judged(r["pass"]), note))
    return out


# MARK: Saturation and Vibrance: V3's bars

METRIC_NAMES = {"ratio%": "chroma-ratio error %", "hueP95": "hue p95", "LP95": "L* p95", "greyC": "grey C*"}


def colour_bar(value, metric):
    return f"{int(value):+d} {METRIC_NAMES[metric]}, mean over the frames"


def colour_bars(sliders):
    bars = json.loads((C.OUT / "bars.json").read_text())
    rows = [Row(s, colour_bar(v, m), stock, limit=b["bar"])
            for s in sliders for stock, values in bars["bars"][s].items() for v, ms in values.items()
            for m, b in ms.items()]
    for s in sliders:
        rows += [Row(s, "reproduces the prototype: worst block ΔE76 mean", "all", limit=bars["reproduce"][s]["meanDE"]),
                 Row(s, "at 0 leaves the print unchanged: runs that differ", "all", limit=0.0)]
    return rows


def colour_scores(binary, sliders, subset, work, log):
    # Its print arrays and Lightroom's cached blocks go to the scorecard's work folder, not V3's evidence.
    C.SCRATCH = work / "colour"
    bars = json.loads((C.OUT / "bars.json").read_text())
    frames, stocks = subset.colour or C.HELD_OUT, subset.colour_stocks or C.ALL_STOCKS
    scores, reproduce, identity = C.score_build(binary, sliders, frames, stocks)
    whole = subset.colour is None and subset.colour_stocks is None
    verdicts = C.judge(scores, {s: {st: bars["bars"][s][st] for st in stocks} for s in sliders})
    rows = [Row(slider, colour_bar(value, metric), stock, got, bar, judged(ok) if whole else SUBSET)
            for slider, stock, value, metric, got, bar, ok in verdicts if got is not None]
    # Over a subset the worst run, or a count of runs, already fails the whole set when it fails; a pass says less.
    for s in sliders:
        limit = bars["reproduce"][s]
        ok = all(d["mean"] <= limit["meanDE"] and d["p99"] <= limit["p99DE"] for d in reproduce[s])
        rows.append(Row(s, "reproduces the prototype: worst block ΔE76 mean", "all",
                        max(d["mean"] for d in reproduce[s]), limit["meanDE"],
                        judged(ok) if whole or not ok else SUBSET,
                        f"worst p99 {max(d['p99'] for d in reproduce[s]):.3f} <= {limit['p99DE']}, "
                        f"{len(reproduce[s])} runs"))
        differing = identity[s].count(False)
        rows.append(Row(s, "at 0 leaves the print unchanged: runs that differ", "all", float(differing), 0.0,
                        judged(differing == 0) if whole or differing else SUBSET, f"{len(identity[s])} runs"))
    return rows


# MARK: Clarity and Texture: V1's held-out bars under the explicit aim

def detail_bars(sliders):
    bars = R.spike_bars()
    rows = []
    for s in sliders:
        for v in R.VALUES:
            bar = bars.get(f"{R.SPIKE_CANDIDATES[s]} {v:+d}")
            if bar:
                where = "crop" if s == "texture" else "blocks"
                rows += [Row(s, f"{s} {v:+d}, mean {bar['metric']}", "both", limit=bar["bar"]),
                         Row(s, f"{s} {v:+d}, parity: rms ΔL* over the {where} against the prototype's change", "both",
                             limit=bar["parity"]["max"])]
    return rows


def detail_scores(binary, sliders, subset, work, log):
    # Lightroom's blocks are cached in the scorecard's work folder, not in the fits' or V1's evidence.
    R.SCRATCH = work / "clarity"
    R.SCRATCH.mkdir(parents=True, exist_ok=True)
    runs = R.score_spike(binary, subset.detail, sliders=tuple(sliders), parity=True, log=log)
    rows = []
    for r in R.judge_spike(runs, R.spike_bars()):
        status = PENDING if r["max"] is None else SUBSET if r["pass"] is None else judged(r["pass"])
        rows.append(Row(r["bar"].split()[0], r["bar"], r["stock"], r["measured"], r["max"], status, r["note"]))
    return rows


@dataclass(frozen=True)
class Suite:
    sliders: tuple
    bars: object
    scores: object


SUITES = (Suite(("dehaze",), dehaze_bars, dehaze_scores),
          Suite(("saturation", "vibrance"), colour_bars, colour_scores),
          Suite(("clarity", "texture"), detail_bars, detail_scores))


# MARK: The run

def reconcile(listed, scored, whole):
    """A suite's whole list of bars with the scorer's rows laid over it, each bar once and in the list's order, so that
    no bar passes unmeasured. A bar with no row is not measured when a subset ran and an error when the full set ran. A
    subset's value from a full run is an error too: its scorer missed some of the bar's runs. A row for a bar off the
    list, or a second row for one bar, is an error, since a verdict the list does not hold would otherwise go unread."""
    key = lambda r: (r.slider, r.bar, r.stock)  # noqa: E731
    names, got, stray = {key(r) for r in listed}, {}, []
    for r in scored:
        if key(r) in got:
            stray.append(replace(r, status=ERROR, note=f"a second row for this bar; {r.note}"))
        elif key(r) not in names:
            stray.append(replace(r, status=ERROR, note=f"not a bar of the scorecard's list; {r.note}"))
        else:
            got[key(r)] = r
    rows = []
    for bar in listed:
        r = got.get(key(bar))
        if r is None:
            rows.append(replace(bar, status=ERROR, note="the scorer returned no score for it") if whole else
                        replace(bar, status=NOT_MEASURED, note="the subset renders none of its runs"))
        elif whole and r.status == SUBSET:
            rows.append(replace(r, status=ERROR, note=f"the scorer scored part of its runs; {r.note}"))
        else:
            rows.append(r)
    return rows + stray


def run(binary, sliders=SLIDERS, subset=SUBSETS["full"], work=None, log=print):
    """Every bar of `sliders` against `binary`: (rows, seconds per part)."""
    whole = subset == SUBSETS["full"]
    work = Path(work or tempfile.mkdtemp())
    work.mkdir(parents=True, exist_ok=True)
    seconds = {}
    t = time.time()
    try:
        rows = identity_rows(binary, sliders, work, log)
    except (Exception, SystemExit) as e:
        rows = [Row(s, f"identity: --{s} 0 prints what no flag prints, bit for bit", "both", status=ERROR, note=str(e))
                for s in sliders]
    seconds["identity"] = time.time() - t
    for suite in SUITES:
        mine = [s for s in suite.sliders if s in sliders]
        if not mine:
            continue
        t = time.time()
        states = {s: stage(binary, s) for s in mine}
        for s, (status, note) in states.items():
            if status:
                log(f"  {s}: {note}")
                rows += [replace(r, status=status, note=note) for r in suite.bars([s])]
        built = [s for s in mine if states[s][0] is None]
        if built:
            try:
                rows += reconcile(suite.bars(built), suite.scores(binary, built, subset, work, log), whole)
            except (Exception, SystemExit) as e:
                rows += [Row(s, "the scorer could not finish", "", status=ERROR, note=str(e)[-1500:]) for s in built]
        seconds["+".join(mine)] = time.time() - t
    return rows, seconds


def exit_code(rows, whole=True):
    """1 on a failure or an error, else 0 only when the full set ran and every bar passed, else 3."""
    if any(r.status in (FAIL, ERROR) for r in rows):
        return 1
    return 0 if whole and all(r.status == PASS for r in rows) else 3


def number(x):
    return "-" if x is None else f"{x:.3f}"


def table(rows, meta):
    lines = ["# Presence scorecard", "",
             f"- Binary: `{meta['binary']}` (sha256 {meta['binarySha256'][:16]})",
             f"- Subset: {meta['subset']}; sliders: {', '.join(meta['sliders'])}",
             f"- Started {meta['started']}, {meta['seconds']['total']:.0f} s: "
             + ", ".join(f"{k} {v:.0f} s" for k, v in meta["seconds"].items() if k != "total"),
             f"- Result: {meta['result']} (exit {meta['exit']}); "
             + ", ".join(f"{n} {s}" for s, n in meta["counts"].items()), ""]
    for slider in sorted({r.slider for r in rows}, key=SLIDERS.index):
        lines += [f"## {slider.capitalize()}", "", "| Bar | Stock | Measured | Limit | Result | Note |",
                  "| --- | --- | ---: | ---: | --- | --- |"]
        lines += [f"| {r.bar} | {r.stock} | {number(r.measured)} | {number(r.limit)} | {r.status} | {r.note} |"
                  for r in rows if r.slider == slider]
        lines.append("")
    return "\n".join(lines)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", type=Path, default=CHECKOUT / ".build" / "release" / "argent-spike",
                        help="the release argent-spike to judge (default: this checkout's)")
    parser.add_argument("--stand-in", action="store_true", help="judge stand_in.py, the prototypes behind the flags")
    parser.add_argument("--slider", action="append", choices=SLIDERS, help="only this slider (repeatable)")
    parser.add_argument("--subset", choices=sorted(SUBSETS), default="full")
    parser.add_argument("--out", type=Path, help="where scorecard.json and scorecard.md go")
    args = parser.parse_args(argv)
    out = args.out or CHECKOUT / ".build" / "presence-scorecard" / args.subset
    out.mkdir(parents=True, exist_ok=True)
    sliders = tuple(s for s in SLIDERS if s in (args.slider or SLIDERS))
    log = lambda *a: print(*a, flush=True)  # noqa: E731
    started = time.time()
    with tempfile.TemporaryDirectory() as tmp:
        binary = stand_in.launcher(tmp) if args.stand_in else args.binary
        if not binary.is_file():
            raise SystemExit(f"no argent-spike at {binary}: build it with swift build -c release --product argent-spike")
        rows, seconds = run(binary, sliders, SUBSETS[args.subset], out / "work", log)
        named = C.SPIKE if args.stand_in else binary
    seconds["total"] = time.time() - started
    code = exit_code(rows, args.subset == "full")
    meta = {"binary": f"{'stand-in over ' if args.stand_in else ''}{named}", "binarySha256": digest(named),
            "subset": args.subset, "sliders": list(sliders), "started": time.strftime("%Y-%m-%d %H:%M", time.localtime(started)),
            "seconds": seconds, "exit": code, "result": {0: "every bar passes", 1: "a bar fails",
                                                         3: "no bar fails, some are not judged"}[code],
            "counts": {s: sum(r.status == s for r in rows) for s in (PASS, FAIL, NOT_BUILT, PENDING, SUBSET,
                                                                     NOT_MEASURED, ERROR)
                       if any(r.status == s for r in rows)}}
    (out / "scorecard.json").write_text(json.dumps({**meta, "rows": [asdict(r) for r in rows]}, indent=1))
    text = table(rows, meta)
    (out / "scorecard.md").write_text(text + "\n")
    log("")
    log(text)
    log(f"Wrote {out / 'scorecard.json'} and {out / 'scorecard.md'}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
