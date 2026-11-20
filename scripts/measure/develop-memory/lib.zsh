# Shared by the develop-memory runs (docs/manual-development-validation.md, "Develops started with
# the frame view open"): the measuring build and its drive hook, the shared app-run lock, a run's
# logs, and the runs themselves. Source it with EVIDENCE set to the dated evidence root, which holds
# build/ (build-measure-app.sh), rolls/ (make-rolls.py) and logs/.
#
# A run is a fresh app on a roll: launched in the background with App Nap off for the run
# (`-NSAppSleepDisabled YES`, a launch argument, not a saved setting), its sheet filled from the disk
# cache and idle, the window as the host gives it. Each run's commands, the hook's replies, the
# develop's timeline and the pictures `shown` wrote go into its own folder under logs/.

: ${EVIDENCE:?set EVIDENCE to the evidence root}
zmodload zsh/datetime
ARGENT_ID=camera.argent.Argent.m3mem
APP=$EVIDENCE/build/Argent-m3mem.app
DRIVE=$EVIDENCE/build/argent-drive
CONTAINER_TMP=$HOME/Library/Containers/$ARGENT_ID/Data/tmp
LOCK=$HOME/Documents/ArgentResearch/.app-run.lock
# The roll's frames the runs open: 11 the portrait (sony_a7_iv_48, RAW 8: its Exif model reads
# MODEL-NAME), 14 the uncompressed CC0 sample and 15 the lossless L ISO 100 copy (both RAW 9).
FRAMES=30

# The shared app-run lock: one measured app at a time, whichever session runs it.
lock_acquire() {
  local holder waited=0
  until mkdir $LOCK 2>/dev/null; do
    holder=$(cat $LOCK/pid 2>/dev/null)
    if [[ -n $holder ]] && ! kill -0 $holder 2>/dev/null && lock_take $holder; then continue; fi
    (( waited++ % 60 == 0 )) && print "lock: waiting for $LOCK (held by ${holder:-?})"
    sleep 1
  done
  print $$ > $LOCK/pid
}
# lock_take HOLDER: removes the lock HOLDER left when it went, if the lock is still HOLDER's. One
# session at a time takes a lock over, the one that makes the takeover folder in it; it moves the lock
# aside only once it has read HOLDER's pid there again, so a lock another session has made since is
# never removed.
lock_take() {
  mkdir $LOCK/takeover 2>/dev/null || return 1
  if [[ $(cat $LOCK/pid 2>/dev/null) != $1 ]] || kill -0 $1 2>/dev/null; then rmdir $LOCK/takeover 2>/dev/null; return 1; fi
  print "lock: $1 has gone, taking its lock"
  mv $LOCK $LOCK.gone.$$ && rm -rf $LOCK.gone.$$
}
# Only the session holding the lock lets it go, takeover folder and all.
lock_release() { [[ $(cat $LOCK/pid 2>/dev/null) == $$ ]] && rm -rf $LOCK }

# The hook's replies for this run, from the unified log, one line each.
log_begin() {
  RUN=$1
  mkdir -p $RUN
  # /usr/bin/log: zsh has a log builtin of its own.
  /usr/bin/log stream --style compact --level info --predicate \
    "subsystem == \"camera.argent.Argent\" AND category == \"drive\" AND processImagePath CONTAINS \"/Argent-m3mem.app/\"" \
    > $RUN/drive.log 2>/dev/null &
  LOGPID=$!
  sleep 1.5  # log stream takes a moment before it delivers
}
log_end() { kill $LOGPID 2>/dev/null; wait $LOGPID 2>/dev/null }

mark() { print $(( $(wc -l < $RUN/drive.log) )) }
# Posts a command without waiting for its reply.
post() {
  print -r -- "$EPOCHREALTIME > $*" >> $RUN/commands.txt
  $DRIVE $ARGENT_ID "$@"
}
# await KIND AFTER [SECONDS]: the first reply of KIND in the log after line AFTER.
await() {
  local kind=$1 after=$2 limit=${3:-30} start=$EPOCHREALTIME line
  while (( EPOCHREALTIME - start < limit )); do
    line=$(tail -n +$(( after + 1 )) $RUN/drive.log | grep -m1 -E "\] drive ($kind): ")
    if [[ -n $line ]]; then
      print -r -- "$EPOCHREALTIME < ${line#*\] drive }" >> $RUN/commands.txt
      print -r -- "${line#*\] drive *: }"
      return 0
    fi
    sleep 0.05
  done
  print -r -- "$EPOCHREALTIME < timeout waiting for $kind" >> $RUN/commands.txt
  print -r -- "timeout waiting for $kind"
  return 1
}
# Posts a command and prints its reply, or an error reply, within DRIVE_TIMEOUT seconds (30).
drive() {
  local m=$(mark) kind=${1%% *}
  post "$@"
  await "$kind|error" $m ${DRIVE_TIMEOUT:-30}
}
# Posts a command whose reply is several lines (picture) and prints those that arrive within 1 s.
drive_all() {
  local m=$(mark) kind=${1%% *}
  post "$@"
  sleep 1
  tail -n +$(( m + 1 )) $RUN/drive.log | grep -E "\] drive $kind: " | sed -E "s/.*\] drive $kind: //"
}
sleep_until() { local d=$(( $1 - EPOCHREALTIME )); (( d > 0 )) && sleep $d; return 0 }
running() { pgrep -f "$APP/Contents/MacOS/Argent" > /dev/null }

# A fresh app on ROLL, launched in the background, once its hook answers with the roll open.
launch() {
  local roll=$1 start=$EPOCHREALTIME reply
  running && { print "error: the measuring app is already running"; return 1 }
  print -r -- "$EPOCHREALTIME launch $roll" >> $RUN/commands.txt
  open -g -n -a $APP $roll --args -NSAppSleepDisabled YES
  while (( EPOCHREALTIME - start < 90 )); do
    reply=$(DRIVE_TIMEOUT=2 drive state 2>/dev/null)
    # By the folder, as m5/app.zsh: the log can cut the line short before "roll".
    [[ $reply == *"${roll:t}\",\"footprint\":"* ]] && return 0
    sleep 0.5
  done
  print "error: no roll ${roll:t} open 90 s after launch"
  return 1
}

# Waits until the sheet has every frame analysed, or failed for good, and the roll settled, and its
# decodes and disk-cache reads have stopped for 2 s, then past the previews' idle trim (2 s) and a
# second more. Records what it saw. The hook puts "0failed" and "0settled" first, beside the phase, so
# the log never cuts them; a reply without them is not settled.
wait_idle() {
  local count=${1:-$FRAMES} start=$EPOCHREALTIME reply frames analyzed failed settled decodes hits last="" stable=0
  while (( EPOCHREALTIME - start < 300 )); do
    reply=$(DRIVE_TIMEOUT=5 drive state)
    [[ $reply =~ '"frames":([0-9]+)' ]] && frames=$match[1]
    [[ $reply =~ '"analyzed":([0-9]+)' ]] && analyzed=$match[1]
    [[ $reply =~ '"0failed":([0-9]+)' ]] && failed=$match[1] || failed=
    [[ $reply =~ '"0settled":(true|false)' ]] && settled=$match[1] || settled=
    [[ $reply =~ '"decodes":([0-9]+)' ]] && decodes=$match[1]
    [[ $reply =~ '"diskHits":([0-9]+)' ]] && hits=$match[1]
    if [[ $frames == $count && -n $failed && $(( analyzed + failed )) == $count && $settled == true && "$decodes $hits" == $last ]]; then
      (( ++stable >= 2 )) && break
    else
      stable=0
    fi
    last="$decodes $hits"
    sleep 1
  done
  print -r -- "idle after $(( EPOCHREALTIME - start )) s: frames $frames, analysed $analyzed, failed ${failed:-?}, settled ${settled:-?}, decodes $decodes, disk reads $hits" >> $RUN/start.txt
  [[ $frames == $count && -n $failed && $(( analyzed + failed )) == $count && $settled == true ]] || { print "error: sheet not idle"; return 1 }
  sleep 3
}

# Quits as Argent > Quit does, which saves first, and waits for the process to end.
quit_app() {
  local start=$EPOCHREALTIME
  drive quit > /dev/null
  while running; do
    if (( EPOCHREALTIME - start > 60 )); then
      print -r -- "$EPOCHREALTIME still running 60 s after quit, killed" >> $RUN/commands.txt
      pkill -f "$APP/Contents/MacOS/Argent"; sleep 2; break
    fi
    sleep 0.2
  done
}

# Moves what the hook wrote into the container's tmp folder (timelines, pictures) into the run's folder.
collect() {
  [[ -d $CONTAINER_TMP ]] || return 0
  local f
  for f in $CONTAINER_TMP/(timeline-*.tsv|film-*.png)(N); do mv $f $RUN/; done
}

# Counts a develop's files and lets them go: the images it wrote (plus any legacy .argent / .argentmasks
# from earlier builds), in the folder it was given inside the roll, then the folder once empty.
clear_output() {
  local out=$1 files
  [[ $out == $EVIDENCE/rolls/*/out-* && -d $out ]] || { print "$out: not a develop folder, kept"; return 1 }
  files=($out/*(N.))
  print "${out:t}: ${#files} files, $(du -sk $out | cut -f1) KB: $(print -l ${files:t} | sed -E 's/.*\.//' | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
  find $out -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.heic' -o -name '*.tif' -o -name '*.argent' -o -name '*.argentmasks' \) -delete
  rmdir $out 2>/dev/null || print "${out:t}: not empty after its images went, kept: $(ls $out | head -5 | tr '\n' ' ')"
}

run_begin() {  # run_begin DIR ROLL
  log_begin $1
  print "run ${1:t} on ${2:t}, $(date '+%Y-%m-%d %H:%M:%S'), load $(sysctl -n vm.loadavg)" >> $1/start.txt
  launch $2 || return 1
  wait_idle || return 1
  { print "memory $(drive memory)"; drive_all picture | sed 's/^/picture /'; print "state $(drive state)" } >> $1/start.txt
}
run_end() {  # run_end DIR ROLL OUT...
  local dir=$1; shift 2
  { print "memory $(drive memory)"; print "state $(drive state)"; print "load $(sysctl -n vm.loadavg)" } >> $dir/end.txt
  quit_app
  log_end
  collect
  local out
  for out in "$@"; do clear_output $out >> $dir/outputs.txt; done
}
develop_line() { print -r -- "$1	$2	$3" >> ${1:h}/runs.tsv }  # develop_line DIR LABEL REPLY

# P, the frame view open: frames 11, 14 and 15 opened for 3 s each, then the round's shown frame for
# 4 s, then the develop; what the frame view shows read as the develop is posted, 1 s into it and 5 s
# after its end.
p_run() {  # p_run DIR ROLL FORMAT SHOWN
  local dir=$1 roll=$2 format=$3 shown=$4 f m posted reply ended out
  run_begin $dir $roll || { develop_line $dir "P ${roll:t} $format frame $shown" "run failed: $(tail -1 $dir/start.txt)"; quit_app; log_end; return 1 }
  for f in 11 14 15; do drive frame $f >> $dir/frames.txt; sleep 3; done
  drive frame $shown >> $dir/frames.txt; sleep 4
  out=$roll/out-${dir:t}
  m=$(mark)
  post develop-measure $out $format timeline
  posted=$EPOCHREALTIME
  print "posted $(drive shown ${dir:t}-posted)" >> $dir/shown.txt
  sleep_until $(( posted + 1 ))
  print "1 s in $(drive shown ${dir:t}-1s)" >> $dir/shown.txt
  reply=$(await develop-measure $m 900)
  ended=$EPOCHREALTIME
  print -r -- $reply > $dir/develop.txt
  sleep_until $(( ended + 5 ))
  print "5 s after $(drive shown ${dir:t}-5s-after)" >> $dir/shown.txt
  run_end $dir $roll $out
  develop_line $dir "P ${roll:t} $format frame $shown" "$reply"
}

# S1, two develops back to back on mixed-b with frame 14 shown, the second with grain Off, posted as
# soon as the first's reply arrives.
s1_run() {  # s1_run DIR ROLL
  local dir=$1 roll=$2 m first second
  run_begin $dir $roll || { develop_line $dir "S1 ${roll:t}" "run failed"; quit_app; log_end; return 1 }
  drive frame 14 >> $dir/frames.txt; sleep 4
  m=$(mark); post develop-measure $roll/out-${dir:t}-1 tiff16 timeline
  first=$(await develop-measure $m 900)
  m=$(mark); post develop-measure $roll/out-${dir:t}-2 tiff16 grain-off timeline
  second=$(await develop-measure $m 900)
  print -r -- $first > $dir/develop.txt; print -r -- $second > $dir/develop-2.txt
  run_end $dir $roll $roll/out-${dir:t}-1 $roll/out-${dir:t}-2
  develop_line $dir "S1 first" "$first"; develop_line $dir "S1 second, grain off" "$second"
}

# S2, the develop posted 0.3 s after frame 14 is opened from frame 11 (on screen 3 s).
s2_run() {  # s2_run DIR ROLL
  local dir=$1 roll=$2 m reply
  run_begin $dir $roll || { develop_line $dir "S2 ${roll:t}" "run failed"; quit_app; log_end; return 1 }
  drive frame 11 >> $dir/frames.txt; sleep 3
  post frame 14; sleep 0.3
  m=$(mark); post develop-measure $roll/out-${dir:t} tiff16 timeline
  reply=$(await develop-measure $m 900); print -r -- $reply > $dir/develop.txt
  run_end $dir $roll $roll/out-${dir:t}
  develop_line $dir "S2" "$reply"
}

# S3, from the idle sheet, frames 0 to 9 opened one a second during the develop, the first 1 s after
# it is posted; 5 s after its end, what the frame view shows.
s3_run() {  # s3_run DIR ROLL
  local dir=$1 roll=$2 m posted i reply ended
  run_begin $dir $roll || { develop_line $dir "S3 ${roll:t}" "run failed"; quit_app; log_end; return 1 }
  m=$(mark); post develop-measure $roll/out-${dir:t} tiff16 timeline; posted=$EPOCHREALTIME
  for i in {0..9}; do sleep_until $(( posted + 1 + i )); post frame $i; done
  reply=$(await develop-measure $m 900); ended=$EPOCHREALTIME; print -r -- $reply > $dir/develop.txt
  sleep_until $(( ended + 5 ))
  print "5 s after $(drive shown ${dir:t}-5s-after)" >> $dir/shown.txt
  run_end $dir $roll $roll/out-${dir:t}
  develop_line $dir "S3" "$reply"
}

# S4, the develop posted while a refinement of frame 14 is under way (the hook opens 14 and posts the
# develop once its refinement has begun).
s4_run() {  # s4_run DIR ROLL
  local dir=$1 roll=$2 m reply
  run_begin $dir $roll || { develop_line $dir "S4 ${roll:t}" "run failed"; quit_app; log_end; return 1 }
  m=$(mark); post develop-measure $roll/out-${dir:t} tiff16 refining:14 timeline
  reply=$(await develop-measure $m 900); print -r -- $reply > $dir/develop.txt
  run_end $dir $roll $roll/out-${dir:t}
  develop_line $dir "S4" "$reply"
}

# S5, frame 14 shown, its exposure set five times during the develop, one a second from 1 s after the
# post (+0.4 to +0.8 EV); 5 s after the end, what the frame view shows. Then the frame's exposure goes
# back to the edit's +0.3 EV, so the roll keeps the declared edit for the runs after.
s5_run() {  # s5_run DIR ROLL
  local dir=$1 roll=$2 m posted k reply ended
  run_begin $dir $roll || { develop_line $dir "S5 ${roll:t}" "run failed"; quit_app; log_end; return 1 }
  drive frame 14 >> $dir/frames.txt; sleep 4
  m=$(mark); post develop-measure $roll/out-${dir:t} tiff16 timeline; posted=$EPOCHREALTIME
  for k in 1 2 3 4 5; do sleep_until $(( posted + k )); post adjust exposure 0.$(( k + 3 )); done
  reply=$(await develop-measure $m 900); ended=$EPOCHREALTIME; print -r -- $reply > $dir/develop.txt
  sleep_until $(( ended + 5 ))
  print "5 s after $(drive shown ${dir:t}-5s-after)" >> $dir/shown.txt
  print "restored $(drive adjust exposure 0.3)" >> $dir/frames.txt; sleep 2
  run_end $dir $roll $roll/out-${dir:t}
  develop_line $dir "S5" "$reply"
}

# R, the declared budget protocol from the idle sheet: the develop alone.
r_run() {  # r_run DIR ROLL FORMAT
  local dir=$1 roll=$2 format=$3 m reply
  run_begin $dir $roll || { develop_line $dir "R ${roll:t} $format" "run failed"; quit_app; log_end; return 1 }
  m=$(mark); post develop-measure $roll/out-${dir:t} $format timeline
  reply=$(await develop-measure $m 900); print -r -- $reply > $dir/develop.txt
  run_end $dir $roll $roll/out-${dir:t}
  develop_line $dir "R ${roll:t} $format" "$reply"
}
