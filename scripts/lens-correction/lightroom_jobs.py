"""Queue lens experiments through the existing probe writer. Never runs Lightroom.

python -I lightroom_jobs.py profile lc3-profile /abs/frame.ARW [--jobs /abs/jobs]
Every family takes NAME FILE and --jobs. READY must already exist there.
Use fresh names: clones already imported in a catalog cannot test import defaults.
Outputs are in exports-NAME beside the jobs directory, one TIFF per named state.
Install the updated Probe.lua before consuming MODE lens-defaults or lens-ranges.
"""
import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lightroom-probe"))
import jobs  # noqa: E402


def states(family):
    if family == "fringe-edges":
        return [("off", {})] + [(f"purple-amount-{n:02}", dict(DefringePurpleAmount=n)) for n in (1, 2, 5, 10, 20)] + [
            ("green-amount-10", dict(DefringeGreenAmount=10)),
            ("both-amount-10", dict(DefringePurpleAmount=10, DefringeGreenAmount=10))]
    if family == "fringe-wheel":
        result = states("defringe")
        for colour, lo in (("Purple", 60), ("Green", 40)):
            for gap in (6, 8):
                result.append((f"{colour.lower()}-pair-{lo}-{lo + gap}",
                               {f"Defringe{colour}Amount": 20, f"Defringe{colour}HueLo": lo,
                                f"Defringe{colour}HueHi": lo + gap}))
        return result
    if family in ("defaults", "ranges"):
        return [(family, {})]
    if family == "profile":
        return [("off", {"LensProfileEnable": 0}), ("on", {"LensProfileEnable": 1})]
    if family == "ca":
        return [("off", {"AutoLateralCA": 0}), ("on", {"AutoLateralCA": 1})]
    if family == "fringe-neutral":
        result = [("off", {})]
        for colour in ("Purple", "Green"):
            for amount in (1, 2, 5, 10, 20):
                result.append((f"{colour.lower()}-amount-{amount:02}", {f"Defringe{colour}Amount": amount}))
            result.append((f"{colour.lower()}-wide", {f"Defringe{colour}Amount": 20,
                          f"Defringe{colour}HueLo": 0, f"Defringe{colour}HueHi": 100}))
        for endpoint in ("Lo", "Hi"):
            for value in (48, 52):
                result.append((f"purple-{endpoint.lower()}-{value}", dict(DefringePurpleAmount=20,
                               DefringePurpleHueLo=value if endpoint == "Lo" else 0,
                               DefringePurpleHueHi=value if endpoint == "Hi" else 100)))
        return result
    if family == "camera-amounts":
        return [(f"distortion-{amount:03}", dict(LensProfileEnable=1, LensProfileSetup="Custom",
                LensProfileName="Camera Settings", LensProfileDistortionScale=amount, LensProfileVignettingScale=0))
                for amount in (0, 50, 100, 150, 200)]
    if family == "amounts":
        result = [("off", {"LensProfileEnable": 0})]
        for control in ("Distortion", "Vignetting"):
            for amount in (0, 50, 100, 150, 200):
                settings = {"LensProfileEnable": 1, "LensProfileSetup": "Custom", "LensProfileDistortionScale": 0,
                            "LensProfileVignettingScale": 0, f"LensProfile{control}Scale": amount}
                result.append((f"{control.lower()}-{amount:03}", settings))
        return result
    result = [("off", {})]
    for colour in ("Purple", "Green"):
        for amount in (0, 1, 2, 5, 10, 20):
            result.append((f"{colour.lower()}-amount-{amount:02}", {f"Defringe{colour}Amount": amount}))
        # Sweep each endpoint separately with the other at the outside limit.
        # This includes broad and narrow intervals without reversing the handles.
        for endpoint in ("Lo", "Hi"):
            for value in range(0, 101, 5):
                if (endpoint == "Lo" and value == 100) or (endpoint == "Hi" and value == 0):
                    continue
                settings = {f"Defringe{colour}Amount": 20, f"Defringe{colour}HueLo": 0,
                            f"Defringe{colour}HueHi": 100, f"Defringe{colour}Hue{endpoint}": value}
                result.append((f"{colour.lower()}-hue-{endpoint.lower()}-{value:03}", settings))
    return result


def write(family, name, source, folder):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name):
        raise SystemExit("NAME must contain only letters, digits, hyphens and underscores")
    if not source.is_file() or any(c in str(source) + str(folder) for c in "\t\r\n"):
        raise SystemExit("FILE must exist; paths must not contain tabs or newlines")
    # Reuse jobs.write's READY check and atomic protocol for an explicitly chosen folder.
    jobs.jobs_dir = lambda: folder
    if not jobs.ready():
        raise SystemExit(f"{folder}/READY is missing")
    inputs = folder.parent / "inputs" / name
    if inputs.exists() or any((folder / f"{name}{ext}").exists() for ext in (".job", ".processed", ".done")):
        raise SystemExit(f"{name} already exists: use a fresh name for fresh catalog imports")
    items = []
    for label, settings in states(family):
        target = jobs.clone(source, inputs / f"{name}_{label}{source.suffix.lower()}")
        if family == "defaults":
            # jobs.clone creates a neutral camera-raw sidecar. Import defaults must
            # see no sidecar and must never pass through settings_for or NEUTRAL.
            target.with_suffix(".xmp").unlink(missing_ok=True)
        else:
            settings = jobs.settings_for(target, settings)
        items.append((target, settings))
    mode = {"defaults": "lens-defaults", "ranges": "lens-ranges"}.get(family)
    jobs.write(name, folder.parent / f"exports-{name}", items, mode=mode, catalog="Argent-lens-session-lc3-r2")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="family", required=True)
    for family in ("defaults", "profile", "amounts", "ca", "defringe", "ranges", "fringe-neutral", "camera-amounts",
                   "fringe-wheel", "fringe-edges"):
        command = sub.add_parser(family)
        command.add_argument("name")
        command.add_argument("file", type=Path)
        command.add_argument("--jobs", type=Path, default=jobs.jobs_dir())
    args = parser.parse_args()
    write(args.family, args.name, args.file.expanduser().resolve(), args.jobs.expanduser().resolve())


if __name__ == "__main__":
    main()
