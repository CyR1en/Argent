#!/bin/zsh
# R, the declared budget protocol from the idle sheet (docs/manual-development-validation.md, "Budget"):
# one round of its six develops, JPEG, HEIC and 16-bit TIFF with mixed-a first. See r_run in lib.zsh.
#
#   scripts/measure/develop-memory/r-runs.zsh EVIDENCE
set -uo pipefail
EVIDENCE=${1:?usage: r-runs.zsh EVIDENCE}
here=${0:A:h}
source $here/lib.zsh
[[ -n ${ARGENT_LOCK_HELD:-} ]] || { lock_acquire; trap lock_release EXIT }
logs=$EVIDENCE/logs/r
mkdir -p $logs
n=0
for format in jpeg heic tiff16; do
  for roll in mixed-a mixed-b; do
    (( n++ ))
    r_run $logs/$(printf %02d $n)-$format-${roll#mixed-} $EVIDENCE/rolls/$roll $format
    print "R $n of 6: $(cut -f2- $logs/runs.tsv | tail -1 | cut -c1-160)"
  done
done
