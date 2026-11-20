#!/bin/zsh
# The terminal steps of the Lightroom mask session (SESSION.md). Everything Lightroom does happens through the plug-in's
# menu command; these are the steps around it.
#
#   session-masks.sh plan       the jobs and the time they are planned to take; writes nothing
#   session-masks.sh prepare    with Lightroom QUIT: make the charts, install the plug-in (the old one is backed up),
#                               create READY, write the jobs, their inputs, their mask tables and the plan
#   session-masks.sh status     what the plug-in has done so far
#   session-masks.sh stop       ask the plug-in to stop at its next item (the same as a STOP file in the jobs folder)
#   session-masks.sh check      are the exports complete and clean
#   session-masks.sh analyze    the report: eight questions, in numbers (masks-report/REPORT.md)
#   session-masks.sh finish     with Lightroom QUIT: take READY away and put the old plug-in back
#   session-masks.sh clean      delete the cloned inputs and mask tables (the exports and the plan stay)
#
# Environment: ARGENT_PROBE_ROOT (default references/lightroom-probe), ARGENT_PROBE_MODULES (Lightroom's Modules folder),
# ARGENT_PROBE_PY (default .venv/bin/python), ARGENT_PROBE_SAMPLES (default samples/). --allow-running skips the check
# that Lightroom is not running (only for trying this script somewhere harmless).
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
root=${ARGENT_PROBE_ROOT:-$repo/references/lightroom-probe}
jobs=$root/jobs
py=${ARGENT_PROBE_PY:-$repo/.venv/bin/python}
export ARGENT_PROBE_ROOT=$root
allow=0
force=()
args=()
for a in "$@"; do
    if [[ $a == --allow-running ]]; then allow=1; force=(--force); else args+=("$a"); fi
done
cmd=${args[1]:-help}

lightroom_running() { pgrep -x "Adobe Lightroom Classic" > /dev/null 2>&1 }
need_quit() {
    if lightroom_running && (( ! allow )); then
        echo "Lightroom Classic is running. Quit it (Lightroom Classic > Quit Lightroom Classic), then run this again." >&2
        exit 1
    fi
}
run() { "$py" -I "$here/$1" "${@:2}" }

case $cmd in
    plan)
        run jobs.py masks --summary
        ;;
    prepare)
        need_quit
        [[ -x $py ]] || { echo "no Python at $py (set ARGENT_PROBE_PY, or run from a checkout with .venv)" >&2; exit 1 }
        mkdir -p "$root/charts-dng" "$jobs"
        # the new charts (always remade: they are deterministic) and the old ones the session also uses, if missing
        run make_charts.py masks "$root/charts-dng"
        [[ -f $root/charts-dng/locality.dng ]] || run make_charts.py locality "$root/charts-dng"
        [[ -f $root/charts-dng/adapt-dark.dng && -f $root/charts-dng/adapt-bright.dng ]] || run make_charts.py adaptation "$root/charts-dng"
        raw=${ARGENT_PROBE_SAMPLES:-$repo/samples}/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW
        [[ -f $raw ]] || { echo "the sample raw is missing: $raw" >&2; exit 1 }
        "$here/install-plugin.sh" "${force[@]}"
        rm -f "$jobs/STOP" "$jobs/STOPPED" "$jobs/ALLDONE"
        printf 'The plug-in only checks that this file exists. Created by session-masks.sh prepare %s.\nRemove it (session-masks.sh finish) when the session is over.\n' "$(date '+%Y-%m-%d %H:%M')" > "$jobs/READY"
        run jobs.py masks
        echo
        echo "READY. Now follow SESSION.md from 'Open Lightroom with the throwaway catalog'."
        ;;
    status)
        run jobs.py status
        for m in STOP STOPPED ALLDONE READY; do [[ -e $jobs/$m ]] && echo "marker: $m" || true; done
        if [[ -f $root/masks-plan.json ]]; then
            "$py" -I - "$root" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
plan = json.loads((root / "masks-plan.json").read_text())
total = done = 0
for job in plan["jobs"]:
    folder = root / f"exports-{job['name']}"
    have = sum(1 for i in job["items"] if (folder / f"{job['name']}_{i}.tif").exists())
    total += len(job["items"]); done += have
    print(f"  {job['name']:<14} {have:>3} of {len(job['items']):>3} exported")
print(f"  {done} of {total} exports in all")
PY
        fi
        ;;
    stop)
        touch "$jobs/STOP"
        echo "STOP written: the plug-in stops at its next item. Wait for the progress bar in Lightroom to go away."
        ;;
    check)
        run analyze_masks.py check --root "$root"
        ;;
    analyze)
        run analyze_masks.py all --root "$root"
        ;;
    finish)
        need_quit
        rm -f "$jobs/READY" "$jobs/STOP"
        "$here/install-plugin.sh" --restore "${force[@]}"
        echo "READY removed and the old plug-in put back."
        ;;
    clean)
        rm -rf "$root"/inputs/m0* "$root/mask-tables"
        echo "removed the cloned inputs and mask tables (exports, the plan and the report stay)"
        ;;
    *)
        sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
        ;;
esac
