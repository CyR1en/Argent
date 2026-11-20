#!/bin/zsh
# M5's engine-level targets (docs/SPEC.md#performance-targets), each a test of
# Tests/ArgentRollTests/PerformanceTargetMeasureTests.swift in a process of its own, one after another,
# in a release build with testing on, under the shared app-run lock so no measured app runs beside them:
#
#   T4  one frame to full-size JPEG, decode to file: the lossless L sample, REPEATS develops (20)
#   T5  340 frames to full-size JPEG: frames a second, on rolls of APFS clones: lossless-l (the
#       lossless L sample, the target's case, all RAW 9's on the default route), gate (the 19 gate
#       raws in turn, the five CC0 samples and the 14 photographyblog frames), uncompressed (the
#       uncompressed CC0 sample) and high-iso (copies of the lossless L and uncompressed samples with
#       the Exif ISO set to 1600, 2000, 2500, 3200, 4000, 5000 and 6400, in turn; docs/decoder.md
#       section 17) and owner (the gate raws with photographyblog's Exif model, which reads
#       MODEL-NAME, written back as the a7 IV's, so they route as the owner's files: RAW 9 takes 17
#       of the 19, RAW 8 lossless M and S; docs/decoder.md section 18)
#   T6  the develop's peak footprint, from the T5 runs, to JPEG, HEIC and 16-bit TIFF
#   T8  the five CC0 samples to 16-bit TIFF against references a build recorded in T8_REFERENCE; when
#       there are none this build records them first, and the comparison is then only run to run
#
#   scripts/measure/m5/engine.zsh EVIDENCE
#
# EVIDENCE gets build.txt (commit, machine, toolchain, when), rolls/, raw/ (each test's whole output)
# and summary.txt (one line a target). For a smoke run, smaller: FRAMES (340), REPEATS (20), ROLLS
# (lossless-l gate; also uncompressed, high-iso, owner), FORMATS (0 1 2: JPEG, HEIC, TIFF), TARGETS (t4 t5
# t8; t5 also gives T6), SKIP_BUILD=1. SUMMARY_ONLY=1 builds and runs nothing and writes summary.txt
# again from EVIDENCE's raw/, given the run's FRAMES, REPEATS, ROLLS, FORMATS and TARGETS. ROLLS_DIR
# keeps the rolls elsewhere (EVIDENCE/rolls); a roll already there with FRAMES files is reused.
# DECODER picks the route (docs/decoder.md, "How the choice works"): unset, RAW 9's, the app's; apple,
# every frame to Apple's RAW 8; inhouse, M8's route; the "before" columns of a decoder change.
# T8_REFERENCE defaults to
# ~/Documents/ArgentResearch/output-references/fixed-arw-raw9, the references recorded with RAW 9 on
# 2026-10-19, kept outside the dated roots so later builds compare against it; the earlier sets stay
# beside it (fixed-arw, 09bd9fc's, the in-house decoder's; fixed-arw-b5534f7). The build is in SCRATCH
# (/tmp/argent-m5-engine-build), apart from the app's .build. The 16-bit TIFF develops of the 340-frame
# rolls write about 90 GB into $TMPDIR, each removed when its test ends. A target is within only
# when its tests exited 0, every frame developed or was compared, and every number it is judged on
# was printed.
set -uo pipefail
cd "$(dirname "$0")/../../.."
repo=$PWD

evidence=${1:?usage: engine.zsh EVIDENCE}
mkdir -p $evidence/raw
evidence=${evidence:A}
frames=${FRAMES:-340} repeats=${REPEATS:-20}
rolls=(${=ROLLS:-lossless-l gate}) formats=(${=FORMATS:-0 1 2}) targets=(${=TARGETS:-t4 t5 t8})
scratch=${SCRATCH:-/tmp/argent-m5-engine-build}
rolls_dir=${ROLLS_DIR:-$evidence/rolls}
decoder=${DECODER:-}
summary_only=${SUMMARY_ONLY:-}
reference=${T8_REFERENCE:-$HOME/Documents/ArgentResearch/output-references/fixed-arw-raw9}
lock_held=${ARGENT_LOCK_HELD:-}
# No measurement switch or stand-in input from the caller's shell: each run sets its own.
for name in ${(k)parameters[(I)ARGENT_*]}; do unset $name; done

if [[ $(xcode-select -p) == */CommandLineTools && -z ${DEVELOPER_DIR:-} ]]; then
  for xcode in /Applications/Xcode*.app(N); do export DEVELOPER_DIR=$xcode/Contents/Developer; break; done
fi
if [[ -z $summary_only ]]; then
  # The stocks as scripts/build-app.sh bakes them from bake/ as it is now.
  stamp=$(scripts/stocks-stamp.sh)
  [[ -f build/stocks/.stamp && $(<build/stocks/.stamp) == $stamp ]] \
    || { print -u2 "error: build/stocks is missing or baked from another bake/; run scripts/build-app.sh first"; exit 1 }
  scripts/fetch-samples.sh --check > /dev/null || { print -u2 "error: samples/ does not match the manifest"; exit 1 }
fi
# The app's launch environment (App/Info.plist, LSEnvironment), so the test processes allocate as the
# app does: MallocLargeCache=0 (docs/M2-shell.md section 10).
app_env=(MallocLargeCache=$(plutil -extract LSEnvironment.MallocLargeCache raw App/Info.plist))
corpus=references/corpus/photographyblog-a7iv
lossless=samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW

[[ -n $summary_only ]] || {
  print "commit $(git rev-parse HEAD)$([[ -n $(git status --porcelain -- Sources Tests Package.swift) ]] && print ' (uncommitted changes)')"
  print "machine $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) >> 30 )) GB, macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  print "toolchain $(swift --version 2>&1 | head -1)"
  print "started $(date '+%Y-%m-%d %H:%M:%S %Z'), frames $frames, repeats $repeats, rolls $rolls, formats $formats"
  print "environment $app_env${decoder:+ ARGENT_DECODER=$decoder}, rolls in $rolls_dir"
  print "stocks $stamp"
} > $evidence/build.txt

flags=(-c release -Xswiftc -enable-testing --scratch-path $scratch)
if [[ -z ${SKIP_BUILD:-} && -z $summary_only ]]; then
  print "== build, $(date '+%H:%M:%S')"
  swift build $flags --build-tests > $evidence/raw/build.log 2>&1 || { print -u2 "error: build failed, see raw/build.log"; exit 1 }
fi

# make_roll NAME FILE...: FRAMES clones of the files in turn, numbered so each has its own name.
make_roll() {
  local name=$1 dir=$rolls_dir/$1 i=0; shift
  local sources=($@)
  if [[ -d $dir ]] && (( $(ls $dir | wc -l) == frames )); then return; fi
  rm -rf $dir; mkdir -p $dir
  while (( i < frames )); do
    local file=${sources[$(( i % $#sources + 1 ))]}
    cp -c $file $dir/$(printf '%04d' $(( i + 1 )))-${file:t}
    (( i++ ))
  done
}

# iso_copies DIR FILE...: a copy of each file in DIR at each of the high-iso roll's ISOs, its Exif
# ISOSpeedRatings and RecommendedExposureIndex rewritten (as DecoderSwitchMeasureTests.copyRaw does).
iso_copies() {
  local dir=$1; shift
  mkdir -p $dir
  python3 -I - $dir $@ <<'PY'
import os, struct, sys
out, files = sys.argv[1], sys.argv[2:]
for iso in (1600, 2000, 2500, 3200, 4000, 5000, 6400):
    for path in files:
        data = bytearray(open(path, 'rb').read())
        u16 = lambda o: struct.unpack_from('<H', data, o)[0]
        u32 = lambda o: struct.unpack_from('<I', data, o)[0]
        entry = lambda ifd, tag: next((ifd + 2 + 12 * i for i in range(u16(ifd)) if u16(ifd + 2 + 12 * i) == tag), None)
        exif = u32(entry(u32(4), 0x8769) + 8)
        e = entry(exif, 0x8827)
        if e is not None and u16(e + 2) == 3: struct.pack_into('<H', data, e + 8, iso)
        e = entry(exif, 0x8832)
        if e is not None and u16(e + 2) == 4: struct.pack_into('<I', data, e + 8, iso)
        name = os.path.basename(path).replace('.ARW', '-ISO%05d.ARW' % iso)
        open(os.path.join(out, name), 'wb').write(data)
PY
}

# a7iv_copies DIR FILE...: a copy of each file in DIR with its IFD0 model written back as ILCE-7M4 where
# it reads otherwise, as DecoderCoverageMeasureTests.asA7IV does.
a7iv_copies() {
  local dir=$1; shift
  mkdir -p $dir
  python3 -I - $dir $@ <<'PY'
import os, struct, sys
out, files = sys.argv[1], sys.argv[2:]
name = b'ILCE-7M4'
for path in files:
    data = bytearray(open(path, 'rb').read())
    u16 = lambda o: struct.unpack_from('<H', data, o)[0]
    u32 = lambda o: struct.unpack_from('<I', data, o)[0]
    ifd0 = u32(4)
    e = next(ifd0 + 2 + 12 * i for i in range(u16(ifd0)) if u16(ifd0 + 2 + 12 * i) == 0x0110)
    count = u32(e + 4)
    at = e + 8 if count <= 4 else u32(e + 8)
    if data[at:at + count].rstrip(b'\0') != name:
        assert u16(e + 2) == 2 and len(name) < count
        data[at:at + count] = name + b'\0' * (count - len(name))
    open(os.path.join(out, os.path.basename(path)), 'wb').write(data)
PY
}

# run LOG ENV... -- FILTER: one test in its own process; its output to raw/LOG.log, its exit code to
# raw/LOG.exit.
run() {
  local log=$evidence/raw/$1.log; shift
  local env=()
  while [[ $1 != -- ]]; do env+=($1); shift; done; shift
  print "== $log:t:r, $(date '+%H:%M:%S')"
  env ARGENT_MEASURE=1 $app_env ${decoder:+ARGENT_DECODER=$decoder} $env swift test $flags --skip-build --filter "PerformanceTargetMeasureTests/$1" > $log 2>&1
  local code=$?
  print $code > ${log:r}.exit
  grep -E '^MEASURE' $log
  (( code == 0 )) || print "   (exit $code, see raw/$log:t)"
  return $code
}

# first LOG PATTERN: the first capture of PATTERN in the log's MEASURE lines, or "?".
first() { grep -E '^MEASURE' $evidence/raw/$1.log 2>/dev/null | sed -nE "s/.*$2.*/\\1/p" | head -1 | grep . || print '?' }
# The decoders line the tests print: the route (RAW 9's, M8's switch or Apple's alone), and the frames
# each decoder takes by header and those fallen back.
decoders="; ((RAW 9's route|the decoder switch|Apple's decoder only)[^;]*);"
under() { [[ $1 != '?' ]] && (( $1 < $2 )) && print within || print MISSED }
# T4 and T5 as revised for RAW 9 (docs/SPEC.md#performance-targets): RAW 9's measured T4 times 1.2, and its
# lossless L T5 after 8f3fa6f divided by 1.2 (400 ms and 3 frames a second before, the in-house decoder's).
t4_target=2400 t5_target=0.45
over() { [[ $1 != '?' ]] && (( $1 >= $2 )) && print within || print MISSED }
# exited LOG: the test's exit code as run kept it; for a log from before run kept them, 0 when its last
# line says the test run passed; "?" when neither tells.
exited() {
  local file=$evidence/raw/$1
  if [[ -f $file.exit ]]; then print -r -- "$(<$file.exit)"
  elif tail -1 $file.log 2>/dev/null | grep -q '^. Test run with .* passed'; then print 0
  else print '?'; fi
}
# failing LOG...: "; LOG exited N" for each of the tests that did not exit 0, for a summary line; and
# passed LOG...: whether every one exited 0.
failing() { local log code; for log; do code=$(exited $log); [[ $code == 0 ]] || print -rn -- "; $log exited $code"; done }
passed() { [[ -z $(failing $@) ]] }
# failed LOG: the frames T5's develop in the log did not develop, or "?".
failed() { first $1 ': [0-9]+ written, ([0-9]+) failed' }

[[ -n $lock_held || -n $summary_only ]] || {
  EVIDENCE=$evidence source scripts/measure/develop-memory/lib.zsh
  lock_acquire
  trap lock_release EXIT
}

if [[ -z $summary_only ]] && (( ${targets[(I)t4]} )); then
  run t4 ARGENT_REPEATS=$repeats -- singleFrame
fi

if [[ -z $summary_only ]] && (( ${targets[(I)t5]} )); then
  for roll in $rolls; do
    case $roll in
      lossless-l) make_roll $roll $repo/$lossless ;;
      gate) make_roll $roll $repo/samples/*.ARW(N) $repo/$corpus/*.arw(N) ;;
      uncompressed) make_roll $roll $repo/samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW ;;
      high-iso)
        [[ -d $rolls_dir/.high-iso-sources ]] || iso_copies $rolls_dir/.high-iso-sources $repo/$lossless \
          $repo/samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW
        make_roll $roll $rolls_dir/.high-iso-sources/*.ARW(N) ;;
      owner)
        [[ -d $rolls_dir/.owner-sources ]] || a7iv_copies $rolls_dir/.owner-sources $repo/$corpus/*.arw(N)
        make_roll $roll $repo/samples/*.ARW(N) $rolls_dir/.owner-sources/*.arw(N) ;;
      *) print -u2 "unknown roll $roll"; continue ;;
    esac
    for format in $formats; do
      run t5-$roll-$format ARGENT_ROLL=$rolls_dir/$roll ARGENT_FORMAT=$format -- roll
    done
  done
fi

if [[ -z $summary_only ]] && (( ${targets[(I)t8]} )); then
  mkdir -p $reference
  rm -f $evidence/raw/t8-record.(log|exit)(N) $evidence/raw/t8-reference-build.txt
  if [[ -z $(print $reference/*.tif(N)) ]]; then
    run t8-record ARGENT_OUTPUT_REFERENCE=$reference ARGENT_RECORD=1 -- outputStability \
      && { sed -n '1,3p' $evidence/build.txt; print "recorded $(date '+%Y-%m-%d %H:%M:%S %Z')" } > $reference/build.txt
  fi
  run t8 ARGENT_OUTPUT_REFERENCE=$reference -- outputStability
  cp $reference/build.txt $evidence/raw/t8-reference-build.txt 2>/dev/null
fi

summary=()
if (( ${targets[(I)t4]} )); then
  median=$(first t4 'T4 .*: median ([0-9.]+) ms')
  summary+=("T4 one frame to full-size JPEG: median $median ms over $repeats develops (target under $t4_target ms, $(passed t4 && under $median $t4_target || print MISSED)$(failing t4)); $(first t4 "$decoders")")
fi

if (( ${targets[(I)t5]} )); then
  for roll in $rolls; do
    log=t5-$roll-0
    fps=$(first $log '; ([0-9.]+) frames a second overall') failed=$(failed $log)
    summary+=("T5 $roll, $frames frames to full-size JPEG: $fps frames a second overall, $failed failed (target $t5_target, $(passed $log && [[ $failed == 0 ]] && over $fps $t5_target || print MISSED)$(failing $log)); after the raws' check $(first $log ', ([0-9.]+) after the raws'), first to last written $(first $log ', ([0-9.]+) first to last'), slowest 30 frames $(first $log ', ([0-9.]+) over the slowest'); $(first $log 'over the slowest [0-9]+; ([^;]*);'); $(first $log "$decoders")")
  done
  for roll in $rolls; do
    # A peak not printed, or a develop with a frame failed, leaves the target missed.
    peaks=() worst=0 whole=1 logs=() names=(JPEG HEIC 16-bit-TIFF)
    for format in $formats; do
      log=t5-$roll-$format
      logs+=($log)
      peak=$(first $log 'T6 .*peak ([0-9]+) MB')
      peaks+=("${names[format + 1]} $peak MB")
      if [[ $peak == '?' ]]; then whole=0; elif (( peak > worst )); then worst=$peak; fi
      [[ $(failed $log) == 0 ]] || { whole=0; peaks[-1]+=" ($(failed $log) failed)" }
    done
    summary+=("T6 $roll develop peak footprint: ${(j:, :)peaks} (target under 2000 MB, $( (( whole )) && passed $logs && under $worst 2000 || print MISSED)$(failing $logs)); test process alone, no sheet or frame view")
  done
fi

if (( ${targets[(I)t8]} )); then
  logs=(t8) note=""
  [[ -f $evidence/raw/t8-record.log ]] && { logs=(t8-record t8) note="; references recorded now by this build, so run to run only" }
  de=$(first t8 "worst frame's mean dE2000 ([0-9.]+)")
  # The frames compared, which the test gives as INCOMPLETE n/total when one was not.
  incomplete=$(first t8 "dE2000 [0-9.]+ .*(INCOMPLETE [0-9]+.[0-9]+)")
  summary+=("T8 output stability, five CC0 samples to 16-bit TIFF: worst frame's mean dE2000 $de$([[ $incomplete != '?' ]] && print " of the frames compared, $incomplete") (target under 0.5, $(passed $logs && [[ $incomplete == '?' ]] && under $de 0.5 || print MISSED)$(failing $logs)); largest pixel $(grep -E '^MEASURE T8 .*\.tif:' $evidence/raw/t8.log 2>/dev/null | sed -nE 's/.*max ([0-9.]+),.*/\1/p' | sort -n | tail -1); against $(head -1 $evidence/raw/t8-reference-build.txt 2>/dev/null || print 'no recorded build')$note")
fi

print -l $summary | tee $evidence/summary.txt
print "== done, $(date '+%H:%M:%S')"
