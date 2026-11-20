#!/bin/zsh
# The fine-detail gap against Lightroom's Raw Details (docs/fine-detail-plan.md, section 4), set by
# set, in a release build with testing on:
#
#   1. FineDetailMeasureTests/arms: R9, R8 and Lightroom's Enhanced DNG beside each raw (LRD), at
#      full size with lens correction off, as half floats
#   2. metrics.py prepare, measure, blocks: LRD registered and fitted to R9, the R9+R8c arm, the
#      engineering metrics, and the blind test's three blocks a frame
#   3. FineDetailMeasureTests/crops: every arm through the film at those blocks
#   4. metrics.py summary, and blind.py page for the set
#
#   scripts/measure/fine-detail/run.zsh EVIDENCE SET...
#
# SET names a folder under RAWS (default the plan's Lightroom inputs,
# ~/Documents/ArgentResearch/fine-detail-20261021.noindex/lightroom/raws): test, dev, high-iso, cc0,
# stilllife. EVIDENCE gets build.txt, logs/, arms/SET/<frame>/ (meta, metrics, blocks, crops) and
# summary-SET.txt. PAIR is the blind test's main pair (r9,lrdfit; a dry run without Lightroom uses
# r9,r9r8c). FILES limits a set to the raws it lists, comma separated. KEEP_ARMS=1 keeps the half-float
# arms (about 1 GB a frame); otherwise they go once the crops are made. SKIP_BUILD=1 builds nothing.
emulate -L zsh
set -euo pipefail
setopt null_glob

evidence=${${1:?usage: run.zsh EVIDENCE SET...}:A}
shift
(( $# )) || { print -u2 "usage: run.zsh EVIDENCE SET..."; exit 2 }
here=${0:A:h}
root=${here:h:h:h}
raws=${RAWS:-$HOME/Documents/ArgentResearch/fine-detail-20261021.noindex/lightroom/raws}
scratch=${SCRATCH:-/tmp/argent-fine-detail-build}
python=$root/.venv/bin/python
pair=${PAIR:-r9,lrdfit}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
for name in ${(k)parameters[(I)ARGENT_*]}; do unset $name; done

mkdir -p $evidence/logs
flags=(-c release -Xswiftc -enable-testing --scratch-path $scratch)
{
  print "commit $(git -C $root rev-parse --short HEAD)$(git -C $root diff --quiet || print ' (dirty)')"
  print "when $(date '+%Y-%m-%d %H:%M:%S %z')"
  print "machine $(sysctl -n machdep.cpu.brand_string), $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  print "power $(pmset -g batt | sed -n 1p)"
  print "toolchain $(swift --version 2>&1 | head -1)"
} > $evidence/build.txt
if [[ -z ${SKIP_BUILD:-} ]]; then
  (cd $root && caffeinate -ims swift build $flags --build-tests > $evidence/logs/build.log 2>&1)
fi

measure() {  # test set
  (cd $root && env ARGENT_MEASURE=1 FINE_DETAIL_RAWS=$raws/$2 FINE_DETAIL_OUT=$evidence/arms/$2 ${FILES:+FINE_DETAIL_FILES=$FILES} \
     caffeinate -ims swift test $flags --skip-build --filter "FineDetailMeasureTests/$1" > $evidence/logs/$2-$1.log 2>&1) \
    || { print -u2 "FineDetailMeasureTests/$1 failed on $2: $evidence/logs/$2-$1.log"; exit 1 }
}

for set in $@; do
  [[ -d $raws/$set ]] || { print -u2 "no set $raws/$set"; exit 2 }
  measure arms $set
  frames=($evidence/arms/$set/*(/))
  for step in prepare measure blocks; do
    $python -I $here/metrics.py $step $frames > $evidence/logs/$set-$step.log 2>&1 \
      || { print -u2 "metrics.py $step failed on $set: $evidence/logs/$set-$step.log"; exit 1 }
  done
  measure crops $set
  [[ -n ${KEEP_ARMS:-} ]] || rm -f $evidence/arms/$set/*/*.f16
  $python -I $here/metrics.py summary $evidence/arms/$set > $evidence/summary-$set.txt
  $python -I $here/blind.py page $evidence/arms/$set --pair $pair >> $evidence/summary-$set.txt 2>&1 || true
  print "$set: $(wc -l < $evidence/summary-$set.txt | tr -d ' ') summary lines in $evidence/summary-$set.txt"
done
