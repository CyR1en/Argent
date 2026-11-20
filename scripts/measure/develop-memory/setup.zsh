#!/bin/zsh
# Prepares the develop-memory runs once the measuring app is built: writes the rolls, fills each
# roll's disk cache (a first launch decodes and analyses every frame), gives every frame of mixed-b
# the 2026-10-15 Light and Curve edit (docs/manual-development-validation.md, "The edit"), then opens
# each roll again to check that its sheet fills from the disk cache and that frames 11, 14 and 15 are
# the portrait, the uncompressed CC0 sample and the ISO 100 copy.
#
#   scripts/measure/develop-memory/setup.zsh EVIDENCE
set -uo pipefail
EVIDENCE=${1:?usage: setup.zsh EVIDENCE}
here=${0:A:h}
source $here/lib.zsh
[[ -x $APP/Contents/MacOS/Argent ]] || { print "error: build the measuring app first (build-measure-app.sh)"; exit 1 }
[[ -d $EVIDENCE/rolls ]] || python3 $here/make-rolls.py ${here:h:h:h} $EVIDENCE/rolls || exit 1
[[ -n ${ARGENT_LOCK_HELD:-} ]] || { lock_acquire; trap lock_release EXIT }
# A saved ArgentDevelopMemoryMB would replace the develop target.
if defaults read $ARGENT_ID ArgentDevelopMemoryMB > /dev/null 2>&1; then
  print "error: ArgentDevelopMemoryMB is set for $ARGENT_ID"; exit 1
fi

fail() { print "error: $1"; quit_app; log_end; exit 1 }

# The edit on frame 0, then on every frame. `adjust` prepares the frame's manual adjustments itself and
# answers that Auto is not ready until the frame view's Auto picture is up, so the first is retried.
edit() {
  local start=$EPOCHREALTIME reply control value
  print "frame 0: $(drive frame 0)"
  until reply=$(drive adjust exposure 0.3) && [[ $reply == "exposure 0.3" ]]; do
    (( EPOCHREALTIME - start > 120 )) && { print "error: frame 0 not ready to adjust: $reply"; return 1 }
    sleep 1
  done
  print "exposure: $reply"
  for control value in contrast 15 highlights -30 shadows 25 whites -10 blacks 5; do
    print "$control: $(drive adjust $control $value)"
  done
  print "tone: $(drive curve tone 0:0 64:56 128:132 192:204 255:255)"
  print "red: $(drive curve red 0:0 128:122 255:255)"
  print "blue: $(drive curve blue 0:6 128:134 255:250)"
  print "copy-all: $(DRIVE_TIMEOUT=300 drive adjust copy-all)"
  sleep 3
  print "state: $(drive state)"
}

for roll in mixed-a mixed-b; do
  log_begin $EVIDENCE/logs/setup/fill-$roll
  launch $EVIDENCE/rolls/$roll || fail "launch on $roll"
  wait_idle || fail "sheet not idle on $roll"
  if [[ $roll == mixed-b ]]; then
    edit >> $RUN/edit.txt || fail "the edit on mixed-b: $(tail -1 $RUN/edit.txt)"
  fi
  drive memory >> $RUN/end.txt
  quit_app; log_end; collect
done
for roll in mixed-a mixed-b; do
  log_begin $EVIDENCE/logs/setup/check-$roll
  launch $EVIDENCE/rolls/$roll || fail "launch on $roll"
  wait_idle || fail "sheet not idle on $roll"
  drive state >> $RUN/end.txt
  for f in 11 14 15; do print "$f $(drive frame $f)"; sleep 2; done >> $RUN/frames.txt
  quit_app; log_end; collect
done
for f in $EVIDENCE/logs/setup/*/start.txt; do print "${f:h:t}: $(grep '^idle' $f)"; done
for f in $EVIDENCE/logs/setup/check-*/frames.txt; do print "${f:h:t}:"; cat $f; done
print "mixed-b edit:"; cat $EVIDENCE/logs/setup/fill-mixed-b/edit.txt
