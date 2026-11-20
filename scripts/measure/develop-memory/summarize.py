#!/usr/bin/env python3
"""Tabulates the develop-memory runs and checks them against the declared pass rules
(docs/manual-development-validation.md, "Develops started with the frame view open"):

- memory: every develop in P, S and R peaks at most at the develop target;
- the frame view: in every P run, 1 s into the develop and 5 s after its end, the picture on top is the
  shown frame's film, never the camera's preview, the placeholder or another frame's, and 5 s after the
  end that film is at the layout's pixels; in S3 and S5, 5 s after the end, it shows the last frame
  opened and its film.

The tests and the look at the pictures are not here. Also reported: the window, the start and peak,
frames a second, the frames with the edit, the gate's floor and largest excess, frames let in alone,
refinements during the develop. Each set asked for, all three by default as set-runs.zsh runs them,
must have its runs.tsv with every develop its runs make, or the check fails.

    summarize.py LOGS [p] [s] [r]
"""
import re
import sys
from pathlib import Path

DEVELOP = re.compile(
    r"(?P<written>\d+) of (?P<total>\d+) written (?P<format>\S+) (?P<space>\S+) grain (?P<grain>\S+), "
    r"(?P<edited>\d+) with Light/Curve, (?P<seconds>[\d.]+) s, (?P<fps>[\d.]+) frames/s, "
    r"peak (?P<peak>\d+) MB from (?P<start>\d+) MB, target (?P<target>\d+) MB, failures (?P<failures>\d+)")
GATE = re.compile(r"gate floor (?P<floor>\d+|none)(?: MB)? read after (?P<read>[\d.]+ s|never) (?P<quiet>quiet|not quiet), "
                  r"largest excess (?P<excess>\d+) MB, admitted (?P<admitted>\d+), waited (?P<waited>\d+), alone (?P<alone>\d+)")
REFINED = re.compile(r"refinements during it: started (\d+)")
SHOWN = re.compile(r"frame (?P<frame>\S+) at (?P<px>\d+) px \| (?:nothing drawn|on top: (?P<top>\S+) (?P<kind>\w+)(?: (?P<w>\d+)x(?P<h>\d+))?)")
FRAME = re.compile(r"\] drive frame: (\S+)")
# The develops each set writes into its runs.tsv, one a line: P 18 (fv-runs.zsh), S 15 in its 12 runs,
# S1's three each developing twice (fv-stress.zsh), R 6 (r-runs.zsh).
DEVELOPS = {"p": 18, "s": 15, "r": 6}


def stem(name):
    return re.sub(r"\.(arw|ARW)$", "", name or "")


def shown_lines(run):
    path = run / "shown.txt"
    return path.read_text().splitlines() if path.exists() else []


def frames_opened(run):
    """The frames the run opened, in order, from the hook's replies."""
    log = run / "drive.log"
    return FRAME.findall(log.read_text()) if log.exists() else []


def window(run):
    """The layout's pixels for the shown frame, as `shown` read it, or the start's picture line."""
    for line in shown_lines(run):
        m = SHOWN.search(line)
        if m:
            return f"{m['px']} px"
    return ""


def check_shown(line, expected):
    """Whether a `shown` line has `expected`'s film on top; returns (ok, film's long side, layout px)."""
    m = SHOWN.search(line)
    if not m or not m["top"]:
        return False, None, None
    ok = stem(m["frame"]) == stem(expected) and stem(m["top"]) == stem(expected) and m["kind"] == "film"
    side = max(int(m["w"]), int(m["h"])) if m["w"] else None
    return ok, side, int(m["px"])


def main():
    logs = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    sets = sys.argv[2:] or list(DEVELOPS)
    if any(name not in DEVELOPS for name in sets):
        sys.exit(f"usage: summarize.py LOGS [p] [s] [r]; no set {', '.join(n for n in sets if n not in DEVELOPS)}")
    failures = []
    for set_name in sets:
        table = logs / set_name / "runs.tsv"
        if not table.exists():
            failures.append(f"{set_name.upper()}: no {table}")
            continue
        rows = table.read_text().splitlines()
        if len(rows) != DEVELOPS[set_name]:
            failures.append(f"{set_name.upper()}: {len(rows)} develops in {table}, not {DEVELOPS[set_name]}")
        print(f"\n## {set_name.upper()}\n")
        print("| Run | Develop | Window | Start | Peak | Target | Frames/s | Written | Edited | Floor, excess, alone | Refinements |")
        print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for row in rows:
            directory, label, reply = (row.split("\t") + ["", ""])[:3]
            run = Path(directory)
            d, g, r = DEVELOP.search(reply), GATE.search(reply), REFINED.search(reply)
            if not d:
                print(f"| {run.name} | {label} | | | | | | | | | {reply[:80]} |")
                failures.append(f"{run.name} {label}: no develop reply ({reply[:80]})")
                continue
            gate = f"{g['floor']}, {g['excess']}, {g['alone']}" if g else ""
            print(f"| {run.name} | {label} | {window(run)} | {d['start']} | {d['peak']} | {d['target']} | {d['fps']} | "
                  f"{d['written']}/{d['total']} | {d['edited']} | {gate} | {r.group(1) if r else ''} |")
            if int(d["peak"]) > int(d["target"]):
                failures.append(f"memory: {run.name} {label} peaked at {d['peak']} MB over {d['target']} MB")
            if d["written"] != d["total"] or d["failures"] != "0":
                failures.append(f"{run.name} {label}: {d['written']} of {d['total']} written, {d['failures']} failures")
            roll_b = "mixed-b" in label or set_name == "s"
            if int(d["edited"]) != (int(d["total"]) if roll_b else 0):
                failures.append(f"{run.name} {label}: {d['edited']} frames with Light/Curve")
        # The frame view's rules.
        for run in sorted(p for p in (logs / set_name).iterdir() if p.is_dir()):
            lines, opened = shown_lines(run), frames_opened(run)
            if set_name == "p" and opened:
                expected = opened[-1]
                for line in lines:
                    if line.startswith("posted"):
                        continue
                    ok, side, px = check_shown(line, expected)
                    if not ok:
                        failures.append(f"frame view: {run.name} {line[:140]}")
                    elif line.startswith("5 s after") and side != px:
                        failures.append(f"frame view: {run.name} 5 s after, film {side} px against the layout's {px}")
                if len(lines) != 3:
                    failures.append(f"frame view: {run.name} has {len(lines)} of 3 readings")
            if set_name == "s" and re.search(r"-s[35]-", run.name):
                after = [l for l in lines if l.startswith("5 s after")]
                ok = bool(after and opened and check_shown(after[0], opened[-1])[0])
                if not ok:
                    failures.append(f"frame view: {run.name} {after[0][:140] if after else 'no reading'}")
    print("\n## Pass rules\n")
    print("\n".join(f"- FAIL {f}" for f in failures) if failures else "- memory and frame view: every check holds")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
