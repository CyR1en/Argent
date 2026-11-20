#!/bin/zsh
# P, the frame view open (docs/manual-development-validation.md, "Develops started with the frame view
# open"): three rounds of JPEG, HEIC and 16-bit TIFF, mixed-a and mixed-b alternated with mixed-a first
# in odd rounds, the round's shown frame 11, 14 and then 15. 18 develops; see p_run in lib.zsh.
#
#   scripts/measure/develop-memory/fv-runs.zsh EVIDENCE
set -uo pipefail
EVIDENCE=${1:?usage: fv-runs.zsh EVIDENCE}
here=${0:A:h}
source $here/lib.zsh
[[ -n ${ARGENT_LOCK_HELD:-} ]] || { lock_acquire; trap lock_release EXIT }
logs=$EVIDENCE/logs/p
mkdir -p $logs
shown=(11 14 15)
n=0
for round in 1 2 3; do
  for format in jpeg heic tiff16; do
    rolls=(mixed-a mixed-b)
    (( round % 2 == 0 )) && rolls=(mixed-b mixed-a)
    for roll in $rolls; do
      (( n++ ))
      p_run $logs/$(printf %02d $n)-r$round-$format-${roll#mixed-} $EVIDENCE/rolls/$roll $format $shown[round]
      print "P $n of 18: $(cut -f2- $logs/runs.tsv | tail -1 | cut -c1-160)"
    done
  done
done
