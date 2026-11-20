#!/bin/zsh
# Installs the Argent Probe plug-in for Lightroom Classic, its jobs folder set to this checkout's
# references/lightroom-probe/jobs. Lightroom loads it at its next launch (or File > Plug-in
# Manager > Add). Quit Lightroom first; never run while a job is being processed.
#
#   install-plugin.sh              install (the plug-in already there is first copied to plugin-backups/)
#   install-plugin.sh --restore    put the plug-in that was there before back (or remove this one if there was none)
#   install-plugin.sh --status     what is installed and where its jobs go
#   install-plugin.sh --sdk 13     install with LrSdkVersion 13.0 in Info.lua: the fallback if Lightroom ignores
#                                  mask tables written by a plug-in declaring 10.0 (SESSION.md)
#   --force                        go on although Lightroom is running
#
# Environment (for trying it somewhere harmless): ARGENT_PROBE_ROOT (default references/lightroom-probe),
# ARGENT_PROBE_MODULES (default ~/Library/Application Support/Adobe/Lightroom/Modules).
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
root=${ARGENT_PROBE_ROOT:-$repo/references/lightroom-probe}
jobs=$root/jobs
backups=$root/plugin-backups
module_folder=${ARGENT_PROBE_MODULES:-"$HOME/Library/Application Support/Adobe/Lightroom/Modules"}
target="$module_folder/ArgentProbe.lrplugin"
source="$here/ArgentProbe.lrplugin"

mode=install; sdk=; force=0
while (( $# )); do
    case $1 in
        --restore) mode=restore ;;
        --status) mode=status ;;
        --sdk) shift; sdk=$1 ;;
        --force) force=1 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

# major.minor.revision from a plug-in folder's Info.lua, or "none"
version_of() {
    local info=$1/Info.lua
    [[ -f $info ]] || { echo none; return }
    local v=$(grep -o 'major = [0-9]*, minor = [0-9]*, revision = [0-9]*' "$info" | grep -o '[0-9]*' | paste -sd. -)
    echo ${v:-unknown}
}

lightroom_running() { pgrep -x "Adobe Lightroom Classic" > /dev/null 2>&1 }

if [[ $mode == status ]]; then
    echo "installed: $(version_of "$target") in $target"
    if [[ -f $target/Probe.lua ]]; then echo "its jobs folder: $(grep -o "local JOBDIR = '[^']*'" "$target/Probe.lua" | cut -d"'" -f2)"; fi
    echo "this checkout's plug-in: $(version_of "$source"), jobs in $jobs"
    ls -1 "$backups" 2>/dev/null | sed 's/^/backup: /'
    exit 0
fi

if lightroom_running && (( ! force )); then
    echo "Lightroom Classic is running. Quit it first (Lightroom Classic > Quit), then run this again." >&2
    exit 1
fi

if [[ $mode == restore ]]; then
    now=$(version_of "$target")
    pick=
    while IFS= read -r b; do   # newest first (the names carry a timestamp)
        [[ -n $b ]] || continue
        if [[ $(version_of "$backups/$b") != $now ]]; then pick=$b; break; fi
    done < <(ls -1 "$backups" 2>/dev/null | sort -r)
    if [[ -z $pick ]]; then
        if [[ -f $backups/.nothing-before ]]; then
            rm -rf "$target"
            echo "there was no plug-in before this one: removed $target"
            exit 0
        fi
        echo "no backup of a different version in $backups: nothing restored" >&2
        exit 1
    fi
    rm -rf "$target"
    cp -R "$backups/$pick" "$target"
    echo "restored $(version_of "$target") from $backups/$pick"
    exit 0
fi

mkdir -p "$jobs" "$module_folder"
if [[ -d $target ]]; then
    have=$(version_of "$target")
    # nothing to protect when the installed plug-in is this one, and one backup per version is enough: installing
    # twice must not bury the original under a copy
    if [[ $have != $(version_of "$source") ]] && ! find "$backups" -maxdepth 1 -name "*-v$have-*" 2> /dev/null | grep -q .; then
        mkdir -p "$backups"
        cp -R "$target" "$backups/ArgentProbe.lrplugin-v$have-$(date +%Y%m%d-%H%M%S)"
        echo "backed up the installed plug-in $have to $backups"
    fi
else
    mkdir -p "$backups"
    touch "$backups/.nothing-before"
fi
mkdir -p "$target"
for f in Info.lua Init.lua RunNow.lua MaskJob.lua; do cp "$source/$f" "$target/$f"; done
sed "s|'@JOBDIR@'|'$jobs'|" "$source/Probe.lua" > "$target/Probe.lua"
if [[ -n $sdk ]]; then
    sed -i '' "s|LrSdkVersion = [0-9.]*|LrSdkVersion = $sdk.0|" "$target/Info.lua"
    echo "Info.lua declares LrSdkVersion $sdk.0"
fi
echo "installed $(version_of "$target") in $target, jobs in $jobs"
