#!/bin/zsh
# The app-level M5 targets (docs/SPEC.md#performance-targets) on the measuring app of build-app.zsh,
# driven through its hook: T1, T2, T3 and T7, each N times and serially, every run a fresh app in the
# foreground with App Nap off (`-NSAppSleepDisabled YES`), under the shared app-run lock. Into
# EVIDENCE/app: a folder a run (the hook's replies, the commands, the state before and after),
# results.tsv with the reply of each run, and summary.txt (and summary-SESSION.txt) with one line a
# target over this invocation's runs. A measurement only on an otherwise idle Mac.
#
#   scripts/measure/m5/app.zsh EVIDENCE [N] [TARGETS]
#
# EVIDENCE holds build/ (build-app.zsh); the rolls go into EVIDENCE/rolls. N is 3 by default, TARGETS
# a subset of "t1 t2 t3 t7". FRAMES (500) sets the rolls' size, T2_SWITCHES (10) and T3_CHANGES (30)
# the counts in a run. The window is left as the host gives it (a tiled window keeps its tile) and
# its content size is added to each reply; WINDOW="W H" asks the hook for that size first. Rolls are
# APFS clones of the 19 gate raws (samples/ and references/corpus/photographyblog-a7iv) in turn, or
# with SOURCES=lossless of the CC0 lossless L sample alone, each given trailing bytes of its own so it
# is a raw of its own to the caches, as make-rolls.py does. Of the gate raws RAW 9 takes the three CC0
# samples in Bayer modes (photographyblog's frames read MODEL-NAME, so they go to RAW 8); `decoders`,
# in each run's start.txt or end.txt, counts the roll's frames.
#
# T1  Contact sheet from embedded previews, cold: a fresh roll of clones (files never read, so none
#     of their pages is in memory), the container's Caches/Argent (linear previews, source digests)
#     removed, a fresh app on its empty state. sheet-measure is armed, then `open -a` hands the roll
#     over; from its arrival to the first sheet cell's preview on screen, every visible cell's, and
#     every frame's preview at the cells' size. The open command to the arrival is added.
# T2  Stock switch on the sheet: a fresh app on the kept roll rolls/sheet-FRAMES, idle (every frame
#     analysed, from the disk cache after its first run), stock-measure.
# T3  Settings change to visible at the frame view's size: the same, the roll's first RAW 9 frame (its
#     first in-house frame on M8's route) opened with the adjustments inspector shown (which prepares it, as for a slider drag), its
#     film up and ready to adjust, then latency.
# T7  Launch to empty state: `open -n -a` with no roll; launch-time gives the process's start to the
#     window's first display frame. The open command to that frame is added. A warm launch: the app
#     has run just before.
set -uo pipefail
evidence=${1:?usage: app.zsh EVIDENCE [N] [TARGETS]}
repeats=${2:-3}
targets=(${=${3:-t1 t2 t3 t7}})
frames=${FRAMES:-500}
here=${0:A:h}
repo=${here:h:h:h}
EVIDENCE=${evidence:A}
source $repo/scripts/measure/develop-memory/lib.zsh
ARGENT_ID=camera.argent.Argent.m5
APP=$EVIDENCE/build/Argent-m5.app
DRIVE=$EVIDENCE/build/argent-drive
CONTAINER=$HOME/Library/Containers/$ARGENT_ID/Data
CONTAINER_TMP=$CONTAINER/tmp
FRAMES=$frames
WINDOW=${WINDOW:-}
SOURCES=${SOURCES:-gate}
OUT=$EVIDENCE/app
# This invocation's rows of results.tsv (target, run, session, time, reply), which the summary covers.
SESSION=$(date +%Y%m%d-%H%M%S)
ROLLS=$EVIDENCE/rolls
SHEET=$ROLLS/sheet-$SOURCES-$FRAMES
[[ -x $APP/Contents/MacOS/Argent && -x $DRIVE ]] || { print "error: no $APP; run build-app.zsh $EVIDENCE first" >&2; exit 1 }
mkdir -p $OUT $ROLLS

# lib.zsh's, for this app.
log_begin() {
  RUN=$1
  mkdir -p $RUN
  /usr/bin/log stream --style compact --level info --predicate \
    "subsystem == \"camera.argent.Argent\" AND category == \"drive\" AND processImagePath CONTAINS \"/Argent-m5.app/\"" \
    > $RUN/drive.log 2>/dev/null &
  LOGPID=$!
  sleep 1.5
}
collect() {
  [[ -d $CONTAINER_TMP ]] || return 0
  local f
  for f in $CONTAINER_TMP/(stock-*.txt|film-*.png)(N); do mv $f $RUN/; done
}

# The 19 gate raws, checked against their recorded SHA-256 values.
sources=($repo/samples/*.ARW(N) $repo/references/corpus/photographyblog-a7iv/*.arw(N))
(( ${#sources} == 19 )) || { print "error: ${#sources} gate raws, not 19 (scripts/fetch-samples.sh, references/corpus)" >&2; exit 1 }
{
  grep -v '^#' $repo/scripts/samples.manifest | awk -v d=$repo/samples '{ print $1 "  " d "/" $3 }'
  grep -v '^#' $here/../develop-memory/photographyblog-a7iv.sha256 | awk -v d=$repo/references/corpus/photographyblog-a7iv '{ print $1 "  " d "/" $2 }'
} | shasum -a 256 -c --quiet - || { print "error: a gate raw is not the recorded file" >&2; exit 1 }
[[ $SOURCES == lossless ]] && sources=($repo/samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW)

# make_roll DIR COUNT TAG: COUNT clones of the gate raws in turn, each with TAG and its number after it.
make_roll() {
  local dir=$1 count=$2 tag=$3 i src dst
  mkdir -p $dir
  for (( i = 1; i <= count; i++ )); do
    src=$sources[$(( (i - 1) % ${#sources} + 1 ))]
    dst=$dir/$(printf %03d $i)-${src:t}
    cp -c $src $dst && print -n "argent-m5 $tag $i" >> $dst || return 1
  done
}

# A fresh app, with ROLL if given, once its hook answers (with the roll open). The launch is posted
# from here, so the app is in front.
launch_app() {
  local roll=${1:-} start=$EPOCHREALTIME reply
  running && { print "error: the measuring app is already running"; return 1 }
  print -r -- "$EPOCHREALTIME launch ${roll:-empty}" >> $RUN/commands.txt
  open -n -a $APP ${roll:+$roll} --args -NSAppSleepDisabled YES
  while (( EPOCHREALTIME - start < 90 )); do
    reply=$(DRIVE_TIMEOUT=1 drive state 2>/dev/null)
    # By the folder: the log truncates the line before "roll" once the recents are many.
    if [[ -n $roll ]]; then [[ $reply == *"${roll:t}\",\"footprint\":"* ]] && return 0
    else [[ $reply == "{"* ]] && return 0; fi
    sleep 0.3
  done
  print "error: no answer${roll:+ with ${roll:t} open} 90 s after launch"
  return 1
}

# lib.zsh's wait_idle with a limit: every frame analysed or failed for good, the roll settled, and the
# decodes and disk reads still for 2 s. The hook puts "0failed" and "0settled" first, beside the phase,
# so the log never cuts them; a reply without them is not settled.
wait_idle() {
  local count=$1 limit=${2:-900} start=$EPOCHREALTIME reply f=0 a=0 x s d h last="" stable=0
  while (( EPOCHREALTIME - start < limit )); do
    reply=$(DRIVE_TIMEOUT=5 drive state)
    [[ $reply =~ '"frames":([0-9]+)' ]] && f=$match[1]
    [[ $reply =~ '"analyzed":([0-9]+)' ]] && a=$match[1]
    [[ $reply =~ '"0failed":([0-9]+)' ]] && x=$match[1] || x=
    [[ $reply =~ '"0settled":(true|false)' ]] && s=$match[1] || s=
    [[ $reply =~ '"decodes":([0-9]+)' ]] && d=$match[1]
    [[ $reply =~ '"diskHits":([0-9]+)' ]] && h=$match[1]
    if [[ $f == $count && -n $x && $(( a + x )) == $count && $s == true && "$d $h" == $last ]]; then
      (( ++stable >= 2 )) && break
    else
      stable=0
    fi
    last="$d $h"
    sleep 1
  done
  print -r -- "idle after $(( EPOCHREALTIME - start )) s: frames $f, analysed $a, failed ${x:-?}, settled ${s:-?}, decodes ${d:-?}, disk reads ${h:-?}" >> $RUN/start.txt
  [[ $f == $count && -n $x && $(( a + x )) == $count && $s == true ]] || { print "sheet not idle within $limit s"; return 1 }
  sleep 3
}

# run_end TARGET K REPLY: the reply into results.tsv, then the app quit and what it wrote collected.
run_end() {
  local reply=${3//$'\t'/ }
  print -r -- "$1	$2	$SESSION	$(date '+%Y-%m-%d %H:%M:%S')	$reply" >> $OUT/results.tsv
  print -r -- "$1 $2: $reply"
  if running; then
    { print "memory $(drive memory)"; print "state $(drive state)" } >> $RUN/end.txt
    quit_app
  fi
  print "load $(sysctl -n vm.loadavg)" >> $RUN/end.txt
  log_end
  collect
}
# WINDOW's size asked for, if set; the window's content size, for the reply.
window_size() {
  [[ -n $WINDOW ]] && print "window $(drive window ${=WINDOW})" >> $RUN/start.txt
  local line=$(drive_all picture | head -1)
  print "picture $line" >> $RUN/start.txt
  [[ $line =~ 'content \(([0-9.]+), ([0-9.]+)\)' ]] && print "window ${match[1]%.0}x${match[2]%.0} pt"
}
run_start() {  # run_start TARGET K
  log_begin $OUT/$1/run-$2-$(date +%H%M%S)
  print "$1 run $2, $(date '+%Y-%m-%d %H:%M:%S'), load $(sysctl -n vm.loadavg)" >> $RUN/start.txt
}
sheet_roll() {
  [[ -d $SHEET ]] && return 0
  make_roll $SHEET $FRAMES "sheet $(date +%s)" && print "made ${SHEET:t}"
}

t1_run() {
  local k=$1 roll=$ROLLS/t1-$1-$(date +%H%M%S) m reply opened window
  make_roll $roll $FRAMES "t1 $k $EPOCHREALTIME" || { print "error: roll not made"; return 1 }
  rm -rf $CONTAINER/Library/Caches/Argent
  run_start t1 $k
  if ! launch_app; then run_end t1 $k "run failed: launch"; rm -rf $roll; return 1; fi
  window=$(window_size)
  sleep 3
  m=$(mark); post sheet-measure 60
  reply=$(await "sheet-armed|error" $m 10)
  print "armed $reply" >> $RUN/start.txt
  m=$(mark); opened=$EPOCHREALTIME
  open -a $APP $roll
  reply=$(await "sheet-measure|error" $m 90)
  [[ $reply =~ 'arrived ([0-9.]+)' ]] && reply+=" | open command to arrival $(printf %.1f $(( (match[1] - opened) * 1000 ))) ms"
  print "decoders $(drive decoders)" >> $RUN/end.txt
  run_end t1 $k "$reply | $window"
  [[ ${KEEP_ROLLS:-} == 1 ]] || rm -rf $roll
}

t2_run() {
  local k=$1 reply window
  run_start t2 $k
  if ! launch_app $SHEET; then run_end t2 $k "run failed: launch"; return 1; fi
  window=$(window_size)
  if ! reply=$(wait_idle $FRAMES); then run_end t2 $k "run failed: $reply"; return 1; fi
  print "decoders $(drive decoders)" >> $RUN/start.txt
  reply=$(DRIVE_TIMEOUT=300 drive stock-measure ${T2_SWITCHES:-10})
  run_end t2 $k "$reply | $window"
}

t3_run() {
  local k=$1 reply index name start window
  run_start t3 $k
  if ! launch_app $SHEET; then run_end t3 $k "run failed: launch"; return 1; fi
  window=$(window_size)
  if ! reply=$(wait_idle $FRAMES); then run_end t3 $k "run failed: $reply"; return 1; fi
  reply=$(drive decoders)
  print "decoders $reply" >> $RUN/start.txt
  [[ $reply =~ 'first (RAW 9|in-house) frame ([0-9]+) ([^|]*)' ]] || { run_end t3 $k "run failed: no RAW 9 or in-house frame"; return 1 }
  index=$match[2] name=${match[3]% }
  print "frame $(drive frame $index)" >> $RUN/start.txt
  print "adjust $(drive adjust show)" >> $RUN/start.txt
  # Its film up at the layout's size, then latency once the frame is ready to adjust.
  start=$EPOCHREALTIME reply="not ready to adjust within 60 s"
  while (( EPOCHREALTIME - start < 60 )); do
    if [[ $(drive shown) == *" film "*"is the last film"* ]]; then
      sleep 2
      print "shown $(drive shown)" >> $RUN/start.txt
      reply=$(DRIVE_TIMEOUT=120 drive latency ${T3_CHANGES:-30})
      [[ $reply == "open a frame that is ready to adjust" ]] || break
    fi
    sleep 1
  done
  run_end t3 $k "$reply | frame $index $name | $window"
}

t7_run() {
  local k=$1 reply opened start
  run_start t7 $k
  sleep 2
  opened=$EPOCHREALTIME
  print -r -- "$opened launch empty" >> $RUN/commands.txt
  open -n -a $APP --args -NSAppSleepDisabled YES
  # Left alone while it starts: launch-time keeps what it saw.
  sleep 3
  start=$EPOCHREALTIME
  reply=""
  while (( EPOCHREALTIME - start < 30 )); do
    reply=$(DRIVE_TIMEOUT=2 drive launch-time 2>/dev/null)
    [[ $reply == *"process start"* ]] && break
    sleep 0.5
  done
  [[ $reply =~ 'shown ([0-9.]+)' ]] && reply+=" | open command to the first frame $(printf %.1f $(( (match[1] - opened) * 1000 ))) ms"
  run_end t7 $k "${reply:-run failed: no launch-time}"
}

lock_acquire
trap lock_release EXIT
running && { print "error: the measuring app is already running" >&2; exit 1 }
{
  print "app.zsh $(date '+%Y-%m-%d %H:%M:%S'): $repeats repeats of $targets, $FRAMES frames of $SOURCES raws, window ${WINDOW:-as given}"
  cat $EVIDENCE/build/built-from.txt
} >> $OUT/runs.txt
if (( ${targets[(I)t2]} || ${targets[(I)t3]} )); then
  sheet_roll || { print "error: ${SHEET:t} not made" >&2; exit 1 }
fi
for target in t1 t2 t3 t7; do
  (( ${targets[(I)$target]} )) || continue
  for (( k = 1; k <= repeats; k++ )); do
    ${target}_run $k
    sleep 2
  done
done

python3 -I - $OUT/results.tsv $SESSION > $OUT/summary-$SESSION.txt <<'EOF'
import re, statistics, sys
rows = [line.rstrip("\n").split("\t", 4) for line in open(sys.argv[1]) if line.strip()]
rows = [r for r in rows if r[2] == sys.argv[2]]
NUMBER = r"([-0-9.]+)"

def runs(target):
    return [r[4] for r in rows if r[0] == target]

def values(replies, pattern):
    found = [re.search(pattern.replace("#", NUMBER), r) for r in replies]
    return [float(m.group(1)) for m in found if m]

def span(replies, pattern):
    v = values(replies, pattern)
    return "median %.1f max %.1f" % (statistics.median(v), max(v)) if v else "none"

def most(replies, pattern):
    v = values(replies, pattern)
    return "%d" % max(v) if v else "?"

def failed(replies, pattern):
    bad = sum(1 for r in replies if not re.search(pattern.replace("#", NUMBER), r))
    return ", %d failed" % bad if bad else ""

lines = []
r = runs("t1")
if r:
    lines.append("T1 contact sheet, %s frames cold, %d runs%s: first paint %s ms (target < 1000); visible sheet (%s cells) %s ms,"
                 " every frame's preview %s ms (target < 3000), from the roll's arrival; open command to arrival %s ms"
                 % (most(r, "# frames, "), len(r), failed(r, "first paint # ms"), span(r, "first paint # ms"),
                    most(r, "frames, # visible"), span(r, "visible sheet # ms"), span(r, "every frame's preview # ms"),
                    span(r, "open command to arrival # ms")))
r = runs("t2")
if r:
    lines.append("T2 stock switch, %d runs%s, %s visible cells (%s Apple-decoded): per-run p50 %s ms, per-run max %s ms (target < 1000);"
                 " first through each stock, per-run max %s ms"
                 % (len(r), failed(r, "visible p50=#ms"), most(r, "# visible cells"), most(r, "[(]# Apple-decoded"),
                    span(r, "visible p50=#ms"), span(r, "visible p50=[0-9.]+ms max=#ms"),
                    span(r, "first through each stock [(][0-9]+[)] p50=[0-9.]+ms max=#ms")))
r = runs("t3")
if r:
    lines.append("T3 settings change to visible, %d runs%s at %s px: per-run p95 %s ms (target < 100), per-run p50 %s ms, per-run max %s ms"
                 % (len(r), failed(r, "visible p50=#ms"), most(r, "^#px"), span(r, "visible p50=[0-9.]+ms p95=#ms"),
                    span(r, "visible p50=#ms"), span(r, "p95=[0-9.]+ms max=#ms")))
r = runs("t7")
if r:
    empty = sum(1 for x in r if "empty state true" in x)
    lines.append("T7 launch to empty state, %d warm runs%s: process start to the first frame %s ms (target < 500); open command to it %s ms;"
                 " empty state in %d of %d"
                 % (len(r), failed(r, "process start to the first frame # ms"), span(r, "process start to the first frame # ms"),
                    span(r, "open command to the first frame # ms"), empty, len(r)))
print("\n".join(lines))
EOF
cp $OUT/summary-$SESSION.txt $OUT/summary.txt
cat $OUT/summary.txt
