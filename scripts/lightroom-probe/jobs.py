"""Jobs for the Argent Probe plug-in in Lightroom Classic (ArgentProbe.lrplugin, Probe.lua).

A job is a text file in the plug-in's jobs folder: an OUT line and ITEM lines, each a photo and the
develop settings it gets on top of the plug-in's neutral ones. The plug-in imports each photo,
applies the settings and exports a 16-bit ProPhoto TIFF named after the photo, so every rendering
needs its own file: raws are cloned (APFS clones, near free) into inputs/<job>/ beside the jobs
folder. Write jobs only once the jobs folder holds READY (DESIGN.md); the plug-in renames a job
<name>.processed and writes <name>.done when it is through.

    python -I jobs.py status
    python -I jobs.py variants NAME FILE [--controls exposure,highlights,...] [--values -100,100]
        every probe variant of FILE (raw or chart): the base, Exposure, and each control at
        -100, -50, -25, 25, 50, 100 (or the listed values), exported to exports-NAME/. The Presence
        controls (texture, clarity, dehaze, vibrance, saturation) are variants too, named only on request.
    python -I jobs.py combos NAME FILE 'LABEL:Key=value;Key=value' ...
        FILE with each listed combination of settings (crs keys, e.g. Highlights2012=-100)
    python -I jobs.py auto NAME LIST
        Lightroom's own Auto on every raw listed in LIST, one path a line: the sliders it chose in
        exports-NAME/auto.tsv, and exports with Auto and without in exports-NAME/auto and neutral
    python -I jobs.py masks [--summary] [--only m00-smoke,m01-partial] [--jobs DIR --root DIR]
        The mask session (masks_plan.py): jobs m00 to m05, each a MODE masks job whose items name a chart
        (cloned into inputs/<job>/), plain develop settings and a JSON file holding the
        MaskGroupBasedCorrections table to write; the plan that ties every item to its question is
        masks-plan.json beside the jobs folder. Refuses without READY, unless --jobs names another
        folder (a dry run: nothing is written to the plug-in's folder). --summary prints the plan and
        its time estimate and writes nothing.
    python -I jobs.py run [--timeout SECONDS]
        Runs the pending jobs with no one at the keyboard: presses Lightroom's menu item "Argent Probe: run
        pending jobs" through accessibility (lr_menu.swift) and waits for every job's .done, watching for a
        dialog. One command for what the owner used to choose by hand.
    python -I jobs.py dump NAME PHOTO...
        MODE dump: the plug-in writes the mask table Lightroom holds for each PHOTO to
        exports-NAME/dump/. The fallback if a table is refused: draw one mask by hand in a throwaway
        catalog, dump it, and compare it with what masks_plan.py writes (SESSION.md).
"""
import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_charts  # noqa: E402
import masks_plan  # noqa: E402
import probe  # noqa: E402

MODULES = Path(os.environ.get("ARGENT_PROBE_MODULES") or Path.home() / "Library/Application Support/Adobe/Lightroom/Modules")
PLUGIN = MODULES / "ArgentProbe.lrplugin/Probe.lua"
KEYS = {"exposure": "Exposure2012", "contrast": "Contrast2012", "highlights": "Highlights2012",
        "shadows": "Shadows2012", "whites": "Whites2012", "blacks": "Blacks2012",
        "texture": "Texture", "clarity": "Clarity2012", "dehaze": "Dehaze", "vibrance": "Vibrance",
        "saturation": "Saturation"}
ITEM_TITLE = "Argent Probe: run pending jobs"
PRESENCE = ["texture", "clarity", "dehaze", "vibrance", "saturation"]
# Formats Lightroom renders without a camera profile of its own: a DNG chart takes its embedded matrix, a TIFF
# is already rendered. Any other file is a camera raw.
NOT_RAW = {".dng", ".tif", ".tiff"}


def jobs_dir():
    """The installed plug-in's jobs folder, or this checkout's when it is not installed."""
    if PLUGIN.exists():
        found = re.search(r"local JOBDIR = '([^']+)'", PLUGIN.read_text())
        if found:
            return Path(found.group(1))
    return probe.DATA / "jobs"


def ready():
    return (jobs_dir() / "READY").exists()


def clone(source, target):
    """An APFS clone of `source`. A camera raw also gets the 2026-10-29 probe's neutral XMP sidecar, which
    Lightroom reads on import. Without it a raw imports with the default Adobe Color look, and the plug-in's
    CameraProfile key does not take the look away; with it the base render is the old probe's to the bit."""
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        subprocess.run(["cp", "-c", str(source), str(target)], check=True)
    sidecar = target.with_suffix(".xmp")
    if target.suffix.lower() not in NOT_RAW and not sidecar.exists():
        sidecar.write_bytes(make_charts.xmp({}))
    return target


def write(name, out, items, mode=None, catalog=None):
    """Writes job `name`: `items` are (path, {crs key: value}). Atomic: the plug-in sees it whole."""
    folder = jobs_dir()
    if not ready():
        raise SystemExit(f"{folder}/READY is missing: the plug-in is not taking jobs")
    lines = ([f"CATALOG\t{catalog}"] if catalog else []) + ([f"MODE\t{mode}"] if mode else []) + [f"OUT\t{out}"] + [f"ITEM\t{p}\t" + ";".join(f"{k}={v}" for k, v in s.items()) for p, s in items]
    tmp = folder / f"{name}.job.tmp"
    tmp.write_text("\n".join(lines) + "\n")
    tmp.rename(folder / f"{name}.job")
    print(f"wrote {folder / (name + '.job')}: {len(items)} items to {out}")


def settings_for(target, settings):
    """A raw item names its profile too, as the brief for the Presence probe asks; on top of the sidecar it
    changes nothing (the smoke test's renders were identical with it and without)."""
    return ({"CameraProfile": "Adobe Standard"} if target.suffix.lower() not in NOT_RAW else {}) | settings


def variant_items(name, source, controls, values=None):
    """The base and each control at each value. The Light controls keep the probe's numbered stems
    (raw_NN_<control>_<value>); a Presence control's stem is <control>_<value>, at `values` or probe.VALUES."""
    source = Path(source)
    inputs = jobs_dir().parent / "inputs" / name
    items = []
    for index, (control, value) in enumerate(probe.variants()):
        if control is not None and (control not in controls or (values and control != "exposure" and value not in values)):
            continue
        stem = "00_base" if control is None else f"{index:02d}_{probe.variant_name(control, value)}"
        target = clone(source, inputs / f"{name}_{stem}{source.suffix.lower()}")
        items.append((target, settings_for(target, {} if control is None else {KEYS[control]: f"{value:g}"})))
    for control in (c for c in PRESENCE if c in controls):
        for value in values or probe.VALUES:
            target = clone(source, inputs / f"{name}_{probe.variant_name(control, value)}{source.suffix.lower()}")
            items.append((target, settings_for(target, {KEYS[control]: f"{value:g}"})))
    return items


def combo_items(name, source, specs):
    source = Path(source)
    inputs = jobs_dir().parent / "inputs" / name
    base = clone(source, inputs / f"{name}_00_base{source.suffix.lower()}")
    items = [(base, settings_for(base, {}))]
    for spec in specs:
        label, _, settings = spec.partition(":")
        values = dict(part.split("=", 1) for part in settings.split(";") if part)
        target = clone(source, inputs / f"{name}_{label}{source.suffix.lower()}")
        items.append((target, settings_for(target, values)))
    return items


def auto_items(name, list_file):
    """Each listed raw, cloned into inputs/`name`/, so nothing Lightroom does can touch the original folder."""
    inputs = jobs_dir().parent / "inputs" / name
    sources = [Path(line.strip()) for line in Path(list_file).read_text().splitlines() if line.strip()]
    names = [source.name.lower() for source in sources]
    if len(set(names)) != len(names):
        raise SystemExit("two raws in the list share a name, and the exports are named after the photo")
    return [(clone(source, inputs / source.name), {}) for source in sources]


def masks(args):
    plan = masks_plan.build()
    if args.summary:
        print(plan.summary())
        return
    if args.jobs:
        folder = Path(args.jobs)
        root = Path(args.root) if args.root else folder.parent
    else:
        if not ready():
            raise SystemExit(f"{jobs_dir()}/READY is missing: the plug-in is not taking jobs")
        folder = jobs_dir()
        root = Path(args.root) if args.root else folder.parent
    charts = Path(args.charts) if args.charts else root / "charts-dng"
    only = args.only.split(",") if args.only else None
    written = masks_plan.write_plan(plan, root, folder, charts, allow_missing=args.allow_missing, only=only)
    print(plan.summary())
    print(f"wrote {len(written)} jobs into {folder}: {', '.join(written)}")
    print(f"inputs, mask tables and masks-plan.json under {root}")


def dump(name, photos):
    out = jobs_dir().parent / f"exports-{name}"
    write(name, out, [(Path(p), {}) for p in photos], mode="dump", catalog=masks_plan.CATALOG_GUARD)


# MARK: Running the jobs

MENU_SOURCE = Path(__file__).resolve().parent / "lr_menu.swift"
LIGHTROOM = "Adobe Lightroom Classic.app/Contents/MacOS"


def menu_tool():
    """lr_menu.swift compiled beside the data. A binary built in a session that has Accessibility is trusted,
    where osascript is not."""
    binary = probe.DATA / "bin" / "lr_menu"
    if not binary.exists() or binary.stat().st_mtime < MENU_SOURCE.stat().st_mtime:
        binary.parent.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
        subprocess.run(["swiftc", "-O", str(MENU_SOURCE), "-o", str(binary)], check=True, env=env)
    return binary


def lightroom_pid():
    found = subprocess.run(["pgrep", "-f", LIGHTROOM], capture_output=True, text=True).stdout.split()
    if len(found) != 1:
        raise SystemExit(f"expected one Lightroom Classic process, found {found or 'none'}")
    return int(found[0])


def installed_version():
    info = PLUGIN.parent / "Info.lua"
    found = re.search(r"VERSION = \{ major = (\d+), minor = (\d+), revision = (\d+)", info.read_text()) if info.exists() else None
    return tuple(int(v) for v in found.groups()) if found else None


def menu(tool, pid, command):
    return subprocess.run([str(tool), str(pid), command], capture_output=True, text=True)


def new_dialogs(before, now):
    """Windows in `now` (lr_menu's `windows` lines) that were not on screen before the run, are visible and are the
    size of a dialog. Lightroom's panels are on screen from its launch and its progress bars are thin strips."""
    seen = {line.split("\t")[0] for line in before}
    found = []
    for line in now:
        number, alpha, _, size, *_ = line.split("\t") + [""]
        width, _, height = size.partition("x")
        if number not in seen and float(alpha or 0) > 0 and int(width or 0) >= 200 and int(height or 0) >= 100:
            found.append(line)
    return found


def dialogs(tool, pid, before):
    return new_dialogs(before, menu(tool, pid, "windows").stdout.splitlines())


def frontmost():
    out = subprocess.run(["lsappinfo", "info", "-only", "pid", subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()],
                         capture_output=True, text=True).stdout
    found = re.search(r"pid\D*(\d+)", out)
    return int(found.group(1)) if found else None


def job_text(path):
    """A pending job's text. The plug-in's own poll may rename it .processed at any moment, even with Lightroom in the
    background (seen in round 2 of the Presence probe: a job taken 1 s after it was written)."""
    try:
        return path.read_text()
    except FileNotFoundError:
        return path.with_suffix(".processed").read_text()


def job_out(text):
    for line in text.splitlines():
        if line.startswith("OUT\t"):
            return Path(line.split("\t", 1)[1])
    return None


def run(timeout, screens):
    """Presses the menu item until a job starts, then waits for every pending job's .done.
    Lightroom shows its full menu bar only while it is the active app, so the press brings it to the front
    (an accessibility attribute, not a click), and the app that was in front gets the focus back once a job
    has started. The plug-in's own poll may start the jobs before the press; either start counts, and once one has
    started nothing is pressed."""
    folder = jobs_dir()
    t0 = time.time()
    pending = sorted(folder.glob("*.job"))
    if not pending:
        print("no pending jobs")
        return
    if not ready():
        raise SystemExit(f"{folder}/READY is missing")
    version = installed_version()
    texts = {job: job_text(job) for job in pending}
    for job in pending:
        mode = next((line.split("\t")[1] for line in texts[job].splitlines() if line.startswith("MODE\t")), None)
        # Before 1.2.0 the plug-in ran any job but auto as a settings job, in whatever catalog is open.
        if mode not in (None, "auto") and (version is None or version < (1, 2, 0)):
            raise SystemExit(f"{job.name} is MODE {mode}, which plug-in {version} would run as a settings job")
    pid, tool = lightroom_pid(), menu_tool()
    before = menu(tool, pid, "windows").stdout.splitlines()
    items = {job: sum(line.startswith("ITEM\t") for line in texts[job].splitlines()) for job in pending}
    outs = {job: job_out(texts[job]) for job in pending}
    done = {job: job.with_suffix(".done") for job in pending}
    stale = [d for d in done.values() if d.exists() and d.stat().st_mtime < t0]
    if stale:
        raise SystemExit(f"a .done older than this run exists for a pending job: {stale[0]}")
    front = frontmost()

    def started():
        return any(d.exists() for d in done.values()) or any(o and o.exists() and o.stat().st_mtime >= t0 for o in outs.values())

    pressed = False
    for attempt in range(1, 4):
        if started():
            break
        if attempt > 1:
            print(f"no sign of the job after {time.time() - t0:.0f} s: pressing again (the first press is often lost)")
        subprocess.run([str(tool), str(pid), "activate"], capture_output=True, text=True)
        for _ in range(50):
            if any(ITEM_TITLE in line for line in menu(tool, pid, "items").stdout.splitlines()):
                break
            time.sleep(0.1)
        result = menu(tool, pid, "press")
        pressed = True
        print(result.stdout.strip() or result.stderr.strip())
        wait_until = time.time() + 20 + min(160, 1.0 * items[pending[0]])
        while time.time() < wait_until and not started():
            time.sleep(1)
        if started():
            break
    else:
        raise SystemExit("no job started after three presses")
    print(f"started {time.time() - t0:.0f} s after {'the first press' if pressed else 'the run began, by the poll, with no press'}")
    if pressed and front and front != pid:
        subprocess.run([str(tool), str(front), "activate"], capture_output=True, text=True)

    while not all(d.exists() for d in done.values()):
        new = dialogs(tool, pid, before)
        if new:
            screens.mkdir(parents=True, exist_ok=True)
            shot = screens / f"dialog-{time.strftime('%Y%m%d-%H%M%S')}.png"
            subprocess.run(["screencapture", "-x", str(shot)])
            raise SystemExit(f"Lightroom opened a window the run did not expect: {new}; screenshot {shot}. Not answering it.")
        if time.time() - t0 > timeout:
            raise SystemExit(f"timed out after {timeout} s; done so far: {[d.name for d in done.values() if d.exists()]}")
        time.sleep(3)
    for job in pending:
        lines = done[job].read_text().splitlines()
        errors = [line for line in lines if line.startswith("ERROR")]
        exports = sorted(outs[job].glob("*.tif"), key=lambda p: p.stat().st_mtime) if outs[job] else []
        stamps = [p.stat().st_mtime for p in exports]
        per = (stamps[-1] - stamps[0]) / (len(stamps) - 1) if len(stamps) > 1 else float("nan")
        print(f"{job.stem}: {items[job]} items, {len(exports)} exports, {len(errors)} errors, "
              f".done {done[job].stat().st_mtime - t0:.0f} s after the run began, {per:.1f} s between exports")
        for line in errors[:5]:
            print(f"  {line}")


def status():
    folder = jobs_dir()
    print(f"jobs folder {folder}, READY {'present' if ready() else 'missing'}")
    for path in sorted(folder.glob("*")):
        if path.suffix == ".done":
            lines = path.read_text().splitlines()
            errors = [line for line in lines if line.startswith("ERROR")]
            print(f"  {path.name}: {lines[-1] if lines else 'empty'}, {len(errors)} errors")
            for line in errors[:5]:
                print(f"    {line}")
        elif path.suffix in (".job", ".processed"):
            print(f"  {path.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    v = sub.add_parser("variants")
    v.add_argument("name")
    v.add_argument("file")
    v.add_argument("--controls", default="exposure," + ",".join(probe.CONTROLS))
    v.add_argument("--values", help="only these values of the five controls, e.g. -100,-50,50,100")
    c = sub.add_parser("combos")
    c.add_argument("name")
    c.add_argument("file")
    c.add_argument("specs", nargs="+")
    a = sub.add_parser("auto")
    a.add_argument("name")
    a.add_argument("list")
    m = sub.add_parser("masks")
    m.add_argument("--summary", action="store_true")
    m.add_argument("--only")
    m.add_argument("--jobs", help="write the job files here instead of the plug-in's folder (no READY needed)")
    m.add_argument("--root", help="where inputs, mask tables and the plan go (default: beside the jobs folder)")
    m.add_argument("--charts", help="the folder of charts (default: ROOT/charts-dng)")
    m.add_argument("--allow-missing", action="store_true", help="do not stop for a chart or raw that is not there")
    r = sub.add_parser("run")
    r.add_argument("--timeout", type=float, default=3600, help="seconds to wait for every .done")
    r.add_argument("--screens", default=str(probe.DATA / "screens"), help="where a dialog's screenshot goes")
    d = sub.add_parser("dump")
    d.add_argument("name")
    d.add_argument("photos", nargs="+")
    args = parser.parse_args()
    if args.command == "status":
        status()
        return
    if args.command == "masks":
        masks(args)
        return
    if args.command == "dump":
        dump(args.name, args.photos)
        return
    if args.command == "run":
        run(args.timeout, Path(args.screens))
        return
    out = jobs_dir().parent / f"exports-{args.name}"
    if args.command == "auto":
        write(args.name, out, auto_items(args.name, args.list), mode="auto")
        return
    if args.command == "variants":
        values = [int(v) for v in args.values.split(",")] if args.values else None
        items = variant_items(args.name, args.file, args.controls.split(","), values)
    else:
        items = combo_items(args.name, args.file, args.specs)
    write(args.name, out, items)


if __name__ == "__main__":
    main()
