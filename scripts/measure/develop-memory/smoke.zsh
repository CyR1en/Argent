#!/bin/zsh
# Tries the tools on the three-frame smoke roll, not a measurement: a launch, the sheet idle, the frames
# opened, a JPEG develop with its timeline and the frame view read during it, the outputs counted and
# let go, the timeline and pictures collected.
#
#   scripts/measure/develop-memory/smoke.zsh EVIDENCE
set -uo pipefail
EVIDENCE=${1:?usage: smoke.zsh EVIDENCE}
here=${0:A:h}
source $here/lib.zsh
[[ -n ${ARGENT_LOCK_HELD:-} ]] || { lock_acquire; trap lock_release EXIT }
FRAMES=3
dir=$EVIDENCE/logs/smoke/$(date +%H%M%S)
roll=$EVIDENCE/rolls/smoke
run_begin $dir $roll || { print "smoke: $(tail -1 $dir/start.txt)"; quit_app; log_end; exit 1 }
for f in 0 1 2; do print "$f $(drive frame $f)"; sleep 2; done >> $dir/frames.txt
m=$(mark); post develop-measure $roll/out-smoke jpeg timeline; posted=$EPOCHREALTIME
print "posted $(drive shown smoke-posted)" >> $dir/shown.txt
sleep_until $(( posted + 1 )); print "1 s in $(drive shown smoke-1s)" >> $dir/shown.txt
reply=$(await develop-measure $m 300); print -r -- $reply > $dir/develop.txt
run_end $dir $roll $roll/out-smoke
for f in start frames shown develop end outputs; do print "== $f"; cat $dir/$f.txt; done
print "== files"; ls -la $dir
