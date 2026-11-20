#!/bin/zsh
# The contact sheet's scrolling, on the measuring app of build-app.zsh, through its hook. Every run is a
# fresh app in the foreground with App Nap off, under the shared app-run lock, on a roll of APFS clones of
# the 19 gate raws (samples/ and references/corpus/photographyblog-a7iv) named as a camera names them, so a
# file name fits its cell and is not truncated, the window at the size a full
# screen on this Mac gives it, the sheet at its default size. A measurement only on an otherwise idle Mac.
#
#   scripts/measure/sheet-scroll/run.zsh OUT NAME [N] [SCENARIOS]
#
# OUT holds NAME.app and argent-drive (build-app.zsh); N is 3, SCENARIOS "first settled cold", ROLL_FRAMES 80.
#   first    what the app has when a roll is opened again: disk caches full, every frame measured, nothing
#            else rendered. The first two passes render what they reach; the sheet is then idle again.
#   settled  the same app, every picture now in memory: the sheet's own cost, at 1200, 2400 and 6000 pt/s.
#   cold     caches removed, scrolling from the moment the roll is up, under the roll's first decodes.
#   quick    settled, at each speed for 6 s, for trying a change.
# The window is asked for WINDOW ("1512 906"); a tiling window manager may give it another size, which each
# run's first line records. A build from before SheetGrid has a SheetProbe whose geometry readers follow the
# scroll: leave them out to compare with it.
# With TRACE=1, one more settled run under xctrace: Time Profiler and Animation Hitches, into OUT/NAME-*.trace.
#
# Results go to OUT/results-NAME.txt, a run's logs and per-frame times to OUT/logs/.
set -uo pipefail
out=${1:?usage: run.zsh OUT NAME [N] [SCENARIOS]}
name=${2:?usage: run.zsh OUT NAME [N] [SCENARIOS]}
repeats=${3:-3}
scenarios=(${=${4:-first settled cold}})
here=${0:A:h}
repo=${here:h:h:h}
EVIDENCE=${out:A}
source $repo/scripts/measure/develop-memory/lib.zsh
ARGENT_ID=camera.argent.Argent.scroll
APP=$EVIDENCE/$name.app
DRIVE=$EVIDENCE/argent-drive
CONTAINER=$HOME/Library/Containers/$ARGENT_ID/Data
CONTAINER_TMP=$CONTAINER/tmp
FRAMES=${ROLL_FRAMES:-80}
WINDOW=${WINDOW:-1512 906}
ROLL=$EVIDENCE/rolls/sheet-$FRAMES
results=$EVIDENCE/results-$name.txt
sources=($repo/samples/*.ARW(N) $repo/references/corpus/photographyblog-a7iv/*.arw(N))
[[ -d $APP && -x $DRIVE ]] || { print "error: $APP or $DRIVE is missing"; exit 1 }
(( ${#sources} )) || { print "error: no gate raws"; exit 1 }
[[ -n ${DEVELOPER_DIR:-} || $(xcode-select -p) != */CommandLineTools ]] || export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

log_begin_app() {
  RUN=$1
  mkdir -p $RUN
  /usr/bin/log stream --style compact --level info --predicate \
    "subsystem == \"camera.argent.Argent\" AND category == \"drive\" AND processImagePath CONTAINS \"/$name.app/\"" \
    > $RUN/drive.log 2>/dev/null &
  LOGPID=$!
  sleep 1.5
}
make_roll() {
  [[ -d $ROLL ]] && return 0
  mkdir -p $ROLL
  local i src dst
  for (( i = 1; i <= FRAMES; i++ )); do
    src=$sources[$(( (i - 1) % ${#sources} + 1 ))]
    dst=$ROLL/$(printf DSC%05d.ARW $(( 4049 + i )))
    cp -c $src $dst && print -n "argent-scroll $i" >> $dst || return 1
  done
}
launch_app() {
  local start=$EPOCHREALTIME reply
  running && { print "error: the measuring app is already running"; return 1 }
  open -n -a $APP $ROLL --args -NSAppSleepDisabled YES
  while (( EPOCHREALTIME - start < 90 )); do
    reply=$(DRIVE_TIMEOUT=1 drive state 2>/dev/null)
    [[ $reply == *"${ROLL:t}\",\"footprint\":"* ]] && return 0
    sleep 0.3
  done
  print "error: no roll 90 s after launch"; return 1
}
sized() { print -r -- "$name window: $(drive "window $WINDOW")" | tee -a $results; sleep 1 }
measure() {  # measure LABEL SPEED SECONDS
  local reply
  reply=$(DRIVE_TIMEOUT=240 drive "scroll-measure $2 $3")
  print -r -- "$name $1 $2pt/s: $reply" | tee -a $results
}
keep() { local f; for f in $CONTAINER_TMP/scroll-*.tsv(N); do mv $f $RUN/; done }
ended() { quit_app; keep; log_end; return 0 }
clear_caches() { rm -rf $CONTAINER/Library/Caches/Argent }

prefill() {
  [[ -f $EVIDENCE/rolls/.filled-$name ]] && return 0
  log_begin_app $EVIDENCE/logs/$name-prefill
  launch_app || { log_end; return 1 }
  wait_idle $FRAMES || { ended; return 1 }
  ended
  touch $EVIDENCE/rolls/.filled-$name
}

run_first() {
  log_begin_app $EVIDENCE/logs/$name-first-$1
  launch_app || { log_end; return 1 }
  wait_idle $FRAMES || { ended; return 1 }
  sized; sleep 2
  measure first-$1 2400 0
  ended
}
settled_app() {
  launch_app || { log_end; return 1 }
  wait_idle $FRAMES || { ended; return 1 }
  sized; sleep 2
  # Every picture up, and past the crossfades and the idle trim.
  DRIVE_TIMEOUT=240 drive "scroll-measure 1500 0" > /dev/null
  sleep 3
}
run_settled() {
  log_begin_app $EVIDENCE/logs/$name-settled-$1
  settled_app || return 1
  measure settled-$1 1200 8
  measure settled-$1 2400 8
  measure settled-$1 6000 8
  print -r -- "$name settled-$1 memory: $(DRIVE_TIMEOUT=5 drive memory)" >> $results
  ended
}
run_quick() {
  log_begin_app $EVIDENCE/logs/$name-quick-$1
  settled_app || return 1
  measure "quick" 1200 6
  measure "quick" 2400 6
  measure "quick" 6000 6
  [[ -n ${SHOT:-} ]] && shot
  ended
}
# With SHOT=NAME: the window as the display shows it while a scroll is under way, as OUT/NAME.png.
shot() {
  local id=$(DRIVE_TIMEOUT=3 drive window-id)
  post "scroll-measure 1500 3"
  sleep 1.7
  screencapture -x -o -l $id $EVIDENCE/$SHOT.png
  sleep 6
}
run_cold() {
  clear_caches
  log_begin_app $EVIDENCE/logs/$name-cold-$1
  launch_app || { log_end; return 1 }
  sized
  measure cold-$1 2400 0
  wait_idle $FRAMES > /dev/null
  ended
  rm -f $EVIDENCE/rolls/.filled-$name
}
run_trace() {
  log_begin_app $EVIDENCE/logs/$name-trace
  settled_app || return 1
  local pid=$(pgrep -f "$APP/Contents/MacOS/Argent") template
  for template in "Time Profiler" "Animation Hitches"; do
    local trace=$EVIDENCE/$name-${template// /}.trace
    rm -rf $trace
    xcrun xctrace record --template "$template" --attach $pid --time-limit 25s --output $trace > $RUN/xctrace.log 2>&1 &
    local tracer=$!
    sleep 5
    measure trace-${template// /} 2400 10
    wait $tracer
  done
  ended
}

lock_acquire
trap 'lock_release' EXIT
pgrep -f "$APP/Contents/MacOS/Argent" > /dev/null && { print "error: $APP is already running"; exit 1 }
make_roll || { print "error: roll not made"; exit 1 }
print -r -- "--- $name $(date '+%Y-%m-%d %H:%M:%S') load $(sysctl -n vm.loadavg) $(cat $EVIDENCE/$name.built-from.txt 2>/dev/null | head -2 | tr '\n' ' ')" >> $results
prefill || { print "error: prefill failed"; exit 1 }
for s in $scenarios; do
  for (( k = 1; k <= repeats; k++ )); do
    run_$s $k || print "run $s $k failed"
  done
done
[[ ${TRACE:-0} == 1 ]] && run_trace
print "results in $results"
