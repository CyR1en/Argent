#!/bin/zsh
# S, the cases P does not reach (docs/manual-development-validation.md, "Develops started with the frame
# view open"), all 16-bit TIFF on mixed-b: S1 three runs, S2 three, S3 two, S4 two and S5 two, in that
# order (S5 last: it changes frame 14's exposure during the develop and puts it back after). See the
# s*_run functions in lib.zsh.
#
#   scripts/measure/develop-memory/fv-stress.zsh EVIDENCE
set -uo pipefail
EVIDENCE=${1:?usage: fv-stress.zsh EVIDENCE}
here=${0:A:h}
source $here/lib.zsh
[[ -n ${ARGENT_LOCK_HELD:-} ]] || { lock_acquire; trap lock_release EXIT }
logs=$EVIDENCE/logs/s
mkdir -p $logs
roll=$EVIDENCE/rolls/mixed-b
n=0
for kind runs in s1 3 s2 3 s3 2 s4 2 s5 2; do
  for run in {1..$runs}; do
    (( n++ ))
    ${kind}_run $logs/$(printf %02d $n)-$kind-$run $roll
    print "S $n of 12: $(cut -f2- $logs/runs.tsv | tail -1 | cut -c1-160)"
  done
done
