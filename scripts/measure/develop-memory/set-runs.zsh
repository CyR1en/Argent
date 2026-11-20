#!/bin/zsh
# Runs the sets under the shared app-run lock, P (fv-runs.zsh), S (fv-stress.zsh) and R (r-runs.zsh)
# by default, then checks every raw's SHA-256 against the value make-rolls.py wrote.
#
#   scripts/measure/develop-memory/set-runs.zsh EVIDENCE [p] [s] [r]
set -uo pipefail
EVIDENCE=${1:?usage: set-runs.zsh EVIDENCE [p] [s] [r]}
shift
here=${0:A:h}
source $here/lib.zsh
sets=(p s r)
(( $# )) && sets=($@)
lock_acquire
trap lock_release EXIT
export ARGENT_LOCK_HELD=1
for set in $sets; do
  print "== $set, $(date '+%H:%M:%S')"
  case $set in
    p) zsh $here/fv-runs.zsh $EVIDENCE ;;
    s) zsh $here/fv-stress.zsh $EVIDENCE ;;
    r) zsh $here/r-runs.zsh $EVIDENCE ;;
    *) print "unknown set $set" ;;
  esac
done
for roll in mixed-a mixed-b; do
  if (cd $EVIDENCE/rolls/$roll && shasum -a 256 --quiet -c ../$roll.sha256); then
    print "$roll: every raw's SHA-256 as written"
  else
    print "$roll: A RAW CHANGED"
  fi
done | tee -a $EVIDENCE/logs/sha256-after.txt
print "== done, $(date '+%H:%M:%S')"
