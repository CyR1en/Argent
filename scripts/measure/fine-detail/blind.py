"""The fine-detail gap's blind test (docs/fine-detail-plan.md, section 4).

`page` builds a self-contained page from the crops `FineDetailMeasureTests/crops` rendered: every
frame's three blocks as the main pair (default R9 against LRD), 24 calibration trials of R8 against
R9, and 14 main trials repeated with their sides swapped. Sides and order are random, from a fixed
seed. The images are copied under anonymous names, and which arm is which is kept in `key.json`, which
the page never loads. `verdict` reads the page's saved answers against the key.

    python blind.py page <set-dir> [--pair r9,lrdfit] [--seed 20261021]   -> <set-dir>/blind/index.html
    python blind.py verdict <set-dir>/blind/key.json <results.json>
"""
import argparse
import hashlib
import json
import shutil
from math import comb
from pathlib import Path

import numpy as np

CALIBRATION = 24
REPEATS = 14


def page(set_dir, pair, seed):
    rng = np.random.default_rng(seed)
    items = []
    for d in sorted(p for p in set_dir.iterdir() if (p / "blocks.json").exists()):
        for k, block in enumerate(json.loads((d / "blocks.json").read_text())):
            crops = {arm: d / "crops" / f"{arm}-{k}.png" for arm in set(pair) | {"r8", "r9"}}
            if all(crops[a].exists() for a in pair):
                items.append({"frame": d.name, "block": k, "rule": block["rule"], "crops": crops})
    if not items:
        raise SystemExit(f"no crops for {pair} under {set_dir}")
    out = set_dir / "blind"
    if out.exists():
        shutil.rmtree(out)
    (out / "img").mkdir(parents=True)

    def image(path):
        name = hashlib.sha256(f"{seed}:{path}".encode()).hexdigest()[:16] + ".png"
        shutil.copyfile(path, out / "img" / name)
        return f"img/{name}"

    trials = []
    def add(item, arms, kind, swap=None):
        left_first = bool(rng.integers(2)) if swap is None else swap
        left, right = (arms[0], arms[1]) if left_first else (arms[1], arms[0])
        trials.append({"kind": kind, "frame": item["frame"], "block": item["block"], "rule": item["rule"],
                       "left": left, "right": right,
                       "leftImage": image(item["crops"][left]), "rightImage": image(item["crops"][right])})
    for item in items:
        add(item, pair, "main")
    main = list(trials)
    for i in rng.choice(len(main), size=min(REPEATS, len(main)), replace=False):
        t = main[int(i)]
        item = next(x for x in items if x["frame"] == t["frame"] and x["block"] == t["block"])
        add(item, pair, "repeat", swap=(t["left"] != pair[0]))
    calibration = [x for x in items if x["crops"]["r8"].exists() and x["crops"]["r9"].exists()]
    for i in rng.choice(len(calibration), size=min(CALIBRATION, len(calibration)), replace=False):
        add(calibration[int(i)], ("r8", "r9"), "calibration")
    order = rng.permutation(len(trials))
    trials = [trials[int(i)] | {"trial": n} for n, i in enumerate(order)]
    (out / "key.json").write_text(json.dumps({"pair": pair, "seed": seed, "trials": trials}, indent=1))
    shown = [{"trial": t["trial"], "left": t["leftImage"], "right": t["rightImage"]} for t in trials]
    (out / "index.html").write_text(HTML.replace("__TRIALS__", json.dumps(shown)).replace("__SEED__", str(seed)))
    print(f"{len(trials)} trials ({len(main)} main, {sum(t['kind'] == 'repeat' for t in trials)} repeats, "
          f"{sum(t['kind'] == 'calibration' for t in trials)} calibration) in {out / 'index.html'}")


def threshold(n):
    """The fewest wins of n with a one-sided binomial p under 0.05."""
    for k in range(n // 2, n + 1):
        if sum(comb(n, i) for i in range(k, n + 1)) / 2 ** n < 0.05:
            return k
    return n + 1


def verdict(key_path, results_path):
    key = json.loads(key_path.read_text())
    answers = {a["trial"]: a["choice"] for a in json.loads(results_path.read_text())["answers"]}
    pair = key["pair"]
    chosen = {}
    for t in key["trials"]:
        if t["trial"] in answers:
            chosen[t["trial"]] = t["left"] if answers[t["trial"]] == "L" else t["right"]
    def tally(kind, arms):
        ts = [t for t in key["trials"] if t["kind"] == kind and t["trial"] in chosen]
        return {a: sum(chosen[t["trial"]] == a for t in ts) for a in arms}, len(ts)
    main, n = tally("main", pair)
    k = threshold(n)
    lines = [f"main, {pair[0]} against {pair[1]}: {main} of {n}; significant at {k} (one-sided p < 0.05)"]
    if main[pair[1]] >= k:
        lines.append(f"  {pair[1]} preferred: a visible gap")
    elif main[pair[0]] >= k:
        lines.append(f"  {pair[0]} preferred")
    else:
        lines.append("  neither preferred: no visible gap")
    calibration, nc = tally("calibration", ("r8", "r9"))
    lines.append(f"calibration, r8 against r9: {calibration} of {nc}")
    repeats = [t for t in key["trials"] if t["kind"] == "repeat" and t["trial"] in chosen]
    agree = 0
    for t in repeats:
        first = next(m for m in key["trials"] if m["kind"] == "main" and m["frame"] == t["frame"] and m["block"] == t["block"])
        agree += first["trial"] in chosen and chosen[first["trial"]] == chosen[t["trial"]]
    lines.append(f"repeats: {agree} of {len(repeats)} chose the same arm again")
    by_rule = {}
    for t in key["trials"]:
        if t["kind"] == "main" and t["trial"] in chosen:
            by_rule.setdefault(t["rule"], {a: 0 for a in pair})[chosen[t["trial"]]] += 1
    lines.append(f"main by crop rule: {by_rule}")
    print("\n".join(lines))


HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Detail blind test</title>
<style>
:root { --bg: #2a2a2a; --fg: #e6e6e6; --dim: #9a9a9a; --edge: #444; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.4 -apple-system, system-ui, sans-serif; }
main { max-width: 900px; margin: 0 auto; padding: 24px 16px; }
h1 { font-size: 17px; font-weight: 600; margin: 0 0 4px; }
p { margin: 6px 0; color: var(--dim); }
.pair { display: flex; gap: 24px; justify-content: center; margin: 28px 0 16px; }
.pair figure { margin: 0; text-align: center; }
.pair img { display: block; image-rendering: pixelated; outline: 1px solid var(--edge); cursor: pointer; }
.pair figcaption { margin-top: 8px; color: var(--dim); }
.bar { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; }
button { font: inherit; color: var(--fg); background: #3a3a3a; border: 1px solid var(--edge); border-radius: 6px; padding: 6px 12px; cursor: pointer; }
#done { display: none; }
</style></head>
<body><main>
<h1>Which shows finer, truer detail with fewer artifacts?</h1>
<p>Press <b>&larr;</b> for the left crop or <b>&rarr;</b> for the right, or click it. <b>Backspace</b> takes back the last answer.
Crops are shown one image pixel to one display pixel; keep the window at its normal zoom.</p>
<div id="test">
  <div class="pair">
    <figure><img id="left" alt="Left crop"><figcaption>Left</figcaption></figure>
    <figure><img id="right" alt="Right crop"><figcaption>Right</figcaption></figure>
  </div>
  <div class="bar"><span id="progress"></span><button id="save">Save answers so far</button></div>
</div>
<div id="done"><p>All trials answered. Save the answers and put the file beside this page.</p>
<button id="save2">Save answers</button></div>
</main>
<script>
const trials = __TRIALS__;
const storeKey = "detail-blind-__SEED__-" + trials.length;
let answers = [];
try { answers = JSON.parse(localStorage.getItem(storeKey) || "[]"); } catch (e) { answers = []; }
let shownAt = performance.now();
const size = 256 / (window.devicePixelRatio || 1);
for (const id of ["left", "right"]) { const img = document.getElementById(id); img.style.width = size + "px"; img.style.height = size + "px"; }
function persist() { try { localStorage.setItem(storeKey, JSON.stringify(answers)); } catch (e) {} }
function show() {
  if (answers.length >= trials.length) { document.getElementById("test").style.display = "none"; document.getElementById("done").style.display = "block"; return; }
  document.getElementById("test").style.display = "block"; document.getElementById("done").style.display = "none";
  const t = trials[answers.length];
  document.getElementById("left").src = t.left; document.getElementById("right").src = t.right;
  document.getElementById("progress").textContent = "Trial " + (answers.length + 1) + " of " + trials.length;
  if (answers.length + 1 < trials.length) { const n = trials[answers.length + 1]; new Image().src = n.left; new Image().src = n.right; }
  shownAt = performance.now();
}
function answer(choice) {
  if (answers.length >= trials.length) return;
  answers.push({ trial: trials[answers.length].trial, choice, ms: Math.round(performance.now() - shownAt) });
  persist(); show();
}
function save() {
  const blob = new Blob([JSON.stringify({ seed: __SEED__, saved: new Date().toISOString(), answers }, null, 1)], { type: "application/json" });
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "detail-blind-results.json"; a.click();
}
document.addEventListener("keydown", e => {
  if (e.key === "ArrowLeft") answer("L");
  else if (e.key === "ArrowRight") answer("R");
  else if (e.key === "Backspace") { answers.pop(); persist(); show(); e.preventDefault(); }
});
document.getElementById("left").addEventListener("click", () => answer("L"));
document.getElementById("right").addEventListener("click", () => answer("R"));
document.getElementById("save").addEventListener("click", save);
document.getElementById("save2").addEventListener("click", save);
show();
</script></body></html>
"""

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["page", "verdict"])
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--pair", default="r9,lrdfit")
    parser.add_argument("--seed", type=int, default=20261021)
    args = parser.parse_args()
    if args.command == "page":
        page(args.paths[0], tuple(args.pair.split(",")), args.seed)
    else:
        verdict(args.paths[0], args.paths[1])
