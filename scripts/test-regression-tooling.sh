#!/bin/bash
# Self-test for scripts/fetch-samples.sh, scripts/regression.py and the M5 engine's summary, on
# small made-up fixtures served from a scratch folder over file:// URLs: no network and no real
# samples. Checks that a valid cache is kept without a fetch, that missing, corrupt, truncated and
# half-downloaded files are fetched, resumed or repaired, that a bad source or a bad manifest fails
# the run, that the regression check fails on a missing, skipped or failed test, a missing line or
# a sample suite's test the list leaves out, and that the engine's summary misses a target whose
# test failed or whose numbers are incomplete.
#
#     scripts/test-regression-tooling.sh
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fetch=$root/scripts/fetch-samples.sh
check=$root/scripts/regression.py
work=$(mktemp -d "${TMPDIR:-/tmp}/argent-tooling-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "pass  $1"; }
fail() { echo "FAIL  $1" >&2; failures=$((failures + 1)); }
# expect <status> <name> <command...>: the command exits with status 0 or non-zero, as asked.
expect() {
  want=$1 name=$2; shift 2
  "$@" > "$work/out" 2>&1; got=$?
  if { [ "$want" = 0 ] && [ "$got" = 0 ]; } || { [ "$want" != 0 ] && [ "$got" != 0 ]; }; then
    pass "$name"
  else
    fail "$name (exit $got)"; sed 's/^/      /' "$work/out" >&2
  fi
}
says() { if grep -qF -- "$2" "$work/out"; then pass "$1"; else fail "$1: no '$2' in output"; sed 's/^/      /' "$work/out" >&2; fi; }
sha() { shasum -a 256 "$1" | awk '{ print $1 }'; }
size() { wc -c < "$1" | tr -d ' '; }
inode() { ls -i "$1" | awk '{ print $1 }'; }

# Two made-up fixtures and a manifest for them.
src=$work/source samples=$work/samples
mkdir -p "$src"
head -c 300000 /dev/urandom > "$src/a.ARW"
head -c 4096 /dev/urandom > "$src/b.ARW"
manifest=$work/samples.manifest
{
  echo "# test manifest"
  for f in a.ARW b.ARW; do echo "$(sha "$src/$f") $(size "$src/$f") $f file://$src/$f"; done
} > "$manifest"
export ARGENT_SAMPLES_MANIFEST=$manifest ARGENT_SAMPLES_DIR=$samples ARGENT_SAMPLES_PROTOCOLS==file
same() { cmp -s "$src/$1" "$samples/$1"; }

# Fetch from nothing.
expect 1 "check fails on an empty folder" "$fetch" --check
says "check names the missing file" "BAD     a.ARW: missing"
[ ! -e "$samples" ] && pass "check creates nothing" || fail "check created $samples"
expect 0 "fetches both files" "$fetch"
same a.ARW && same b.ARW && pass "fetched bytes match" || fail "fetched bytes differ"
[ ! -e "$samples/.incoming" ] && pass "no download folder left" || fail "download folder left behind"
expect 0 "check passes after the fetch" "$fetch" --check

# A valid cache is kept as it is, and the source is not read: hide the source.
before=$(inode "$samples/a.ARW")
mv "$src" "$src.away"
expect 0 "valid cache accepted with the source gone" "$fetch"
says "valid cache reported ok" "ok      a.ARW"
[ "$(inode "$samples/a.ARW")" = "$before" ] && pass "valid file not rewritten" || fail "valid file rewritten"

# A missing file with the source gone fails, clearly, and leaves nothing in place.
rm "$samples/b.ARW"
expect 1 "unreachable source fails" "$fetch"
says "failure names the file" "could not be fetched"
[ ! -e "$samples/b.ARW" ] && pass "no file in place after a failed fetch" || fail "file in place after a failed fetch"
mv "$src.away" "$src"

# A same-size corrupt file fails the check and is repaired.
expect 0 "refetch the missing file" "$fetch"
python3 - "$samples/a.ARW" <<'PY'
import sys

with open(sys.argv[1], "r+b") as sample:
    sample.seek(1000)
    byte = sample.read(1)[0]
    sample.seek(1000)
    sample.write(bytes([byte ^ 0xFF]))
PY
expect 1 "check fails on a corrupt file" "$fetch" --check
says "check names the hash" "a.ARW: SHA-256"
expect 0 "repairs a corrupt file" "$fetch"
same a.ARW && pass "repaired bytes match" || fail "repaired bytes differ"

# A truncated file fails the check and is repaired.
head -c 1000 "$src/a.ARW" > "$samples/a.ARW"
expect 1 "check fails on a truncated file" "$fetch" --check
says "check names the size" "a.ARW: size 1000, want 300000"
expect 0 "repairs a truncated file" "$fetch"
same a.ARW && pass "repaired truncated bytes match" || fail "repaired truncated bytes differ"

# An interrupted download is resumed from where it stopped.
rm "$samples/a.ARW"
mkdir -p "$samples/.incoming"
head -c 120000 "$src/a.ARW" > "$samples/.incoming/a.ARW"
expect 0 "resumes an interrupted download" "$fetch"
says "resume reported" "resume  a.ARW from byte 120000"
same a.ARW && pass "resumed bytes match" || fail "resumed bytes differ"

# A partial download of the wrong bytes is thrown away and fetched from the start.
rm "$samples/a.ARW"
mkdir -p "$samples/.incoming"
head -c 120000 /dev/urandom > "$samples/.incoming/a.ARW"
expect 0 "recovers from a wrong partial download" "$fetch"
says "retry reported" "retry   a.ARW"
same a.ARW && pass "recovered bytes match" || fail "recovered bytes differ"

# A source serving other bytes than the manifest's fails, and nothing lands in place.
rm "$samples/b.ARW"
cp "$src/b.ARW" "$work/b.good"
head -c 4096 /dev/urandom > "$src/b.ARW"
expect 1 "wrong bytes from the source fail" "$fetch"
says "failure gives the attempts" "after 3 attempts"
[ ! -e "$samples/b.ARW" ] && pass "wrong bytes never in place" || fail "wrong bytes in place"
[ ! -e "$samples/.incoming/b.ARW" ] && pass "wrong complete download removed" || fail "wrong complete download kept"
cp "$work/b.good" "$src/b.ARW"
expect 0 "fetches once the source is right" "$fetch"

# Only https by default: the file:// source is refused.
rm "$samples/b.ARW"
expect 1 "default protocols refuse file://" env ARGENT_SAMPLES_PROTOCOLS= "$fetch"
expect 1 "https-only refuses file://" env ARGENT_SAMPLES_PROTOCOLS==https "$fetch"
expect 0 "fetch again" "$fetch"

# A malformed manifest fails before any fetch.
echo "nothex 12 c.ARW file://$src/a.ARW" >> "$manifest"
expect 1 "malformed manifest fails" "$fetch" --check
says "malformed line named" "malformed manifest line for 'c.ARW'"
invalid_samples=$work/invalid-samples
expect 1 "malformed later line fails before any fetch" env ARGENT_SAMPLES_DIR="$invalid_samples" "$fetch"
[ ! -e "$invalid_samples" ] && pass "malformed manifest creates nothing" || fail "malformed manifest touched fixtures"

# Filenames are unique, including case variants on a case-insensitive Mac filesystem.
printf '%s %s a.ARW file://%s/a.ARW\n' "$(sha "$src/a.ARW")" "$(size "$src/a.ARW")" "$src" > "$manifest"
printf '%s %s a.ARW file://%s/b.ARW\n' "$(sha "$src/b.ARW")" "$(size "$src/b.ARW")" "$src" >> "$manifest"
expect 1 "duplicate manifest filename fails before any fetch" env ARGENT_SAMPLES_DIR="$invalid_samples" "$fetch"
says "duplicate filename named" "duplicate manifest filename 'a.ARW'"
[ ! -e "$invalid_samples" ] && pass "duplicate manifest creates nothing" || fail "duplicate manifest touched fixtures"
sed '2s/a.ARW/A.arw/' "$manifest" > "$work/case.manifest"
expect 1 "case-insensitive duplicate filename fails" env ARGENT_SAMPLES_MANIFEST="$work/case.manifest" "$fetch" --check

# Dot paths, hidden files, option-like names and path components cannot target a fixture.
for name in . .. .incoming -a.ARW ../a.ARW folder/a.ARW; do
  printf '%s %s %s file://%s/a.ARW\n' "$(sha "$src/a.ARW")" "$(size "$src/a.ARW")" "$name" "$src" > "$manifest"
  expect 1 "unsafe manifest filename '$name' fails" env ARGENT_SAMPLES_DIR="$invalid_samples" "$fetch"
done
[ ! -e "$invalid_samples" ] && pass "unsafe manifest creates nothing" || fail "unsafe manifest touched fixtures"
printf '# nothing\n' > "$manifest"
expect 1 "empty manifest fails" "$fetch"

# The regression check, on made-up reports.
list=$work/list.txt
cat > "$list" <<'EOF'
test Mod.Suite/one()
test Mod.Suite/two(x:)
exclude Mod.Suite/slow() asserts a time
output MEASURE marker:
EOF
report() {
  { echo '<?xml version="1.0" encoding="UTF-8"?><testsuites><testsuite name="TestResults">'; cat; echo '</testsuite></testsuites>'; } > "$work/report.xml"
}
echo "MEASURE marker: 1" > "$work/log"
expect 0 "filter regex" python3 "$check" filter "$list"
says "filter escapes each id" 'Mod\.Suite/one\(\)|Mod\.Suite/two\(x:\)'

report <<'EOF'
<testcase classname="Mod.Suite" name="one()" time="1"/><testcase classname="Mod.Suite" name="two(x:)" time="1"/>
EOF
expect 0 "check passes when every required test passed" python3 "$check" check "$list" "$work/log" "$work/report.xml"
expect 1 "check fails without the expected line" python3 "$check" check "$list" /dev/null "$work/report.xml"
expect 1 "check fails without a report" python3 "$check" check "$list" "$work/log" "$work/none.xml"

report <<'EOF'
<testcase classname="Mod.Suite" name="one()" time="1"/>
EOF
expect 1 "check fails on a required test that did not run" python3 "$check" check "$list" "$work/log" "$work/report.xml"
says "missing test named" "did not run: Mod.Suite/two(x:)"

report <<'EOF'
<testcase classname="Mod.Suite" name="one()"><skipped/></testcase><testcase classname="Mod.Suite" name="two(x:)" time="1"/>
EOF
expect 1 "check fails on a skipped required test" python3 "$check" check "$list" "$work/log" "$work/report.xml"
says "skip named" "required test skipped: Mod.Suite/one()"

report <<'EOF'
<testcase classname="Mod.Suite" name="one()" time="1"/><testcase classname="Mod.Suite" name="two(x:)" time="1"/><testcase classname="Mod.Suite" name="three()"><skipped/></testcase>
EOF
expect 1 "check fails on any skipped test in the run" python3 "$check" check "$list" "$work/log" "$work/report.xml"

report <<'EOF'
<testcase classname="Mod.Suite" name="one()" time="1"/><testcase classname="Mod.Suite" name="two(x:)" time="1"><failure message="no"/></testcase>
EOF
expect 1 "check fails on a failed test" python3 "$check" check "$list" "$work/log" "$work/report.xml"

report <<'EOF'
<testcase classname="Mod.Suite" name="one()" time="1"/><testcase classname="Mod.Suite" name="two(x:)" time="1"/><testcase classname="Mod.Suite" name="two(x:)"><failure message="one argument failed"/></testcase>
EOF
expect 1 "one failed parameterized case fails the required test" python3 "$check" check "$list" "$work/log" "$work/report.xml"

report <<'EOF'
<testcase classname="Mod.Suite" name="one()" time="1"/><testcase classname="Mod.Suite" name="two(x:)"><failure message="one argument failed"/></testcase><testcase classname="Mod.Suite" name="two(x:)" time="1"/>
EOF
expect 1 "a later passed case cannot hide a failed argument" python3 "$check" check "$list" "$work/log" "$work/report.xml"

report <<'EOF'
<testcase classname="Mod.Suite" name="one()" time="1"/><testcase classname="Mod.Suite" name="two(x:)" time="1"/><testcase classname="Mod.Suite" name="slow()" time="1"/>
EOF
expect 1 "check fails when an excluded test runs" python3 "$check" check "$list" "$work/log" "$work/report.xml"

# Reports from several modules are read together, and one module's filter keeps to it.
report <<'EOF'
<testcase classname="Mod.Suite" name="one()" time="1"/>
EOF
mv "$work/report.xml" "$work/first.xml"
report <<'EOF'
<testcase classname="Mod.Suite" name="two(x:)" time="1"/>
EOF
expect 0 "check reads several reports" python3 "$check" check "$list" "$work/log" "$work/first.xml" "$work/report.xml"
printf 'test Alpha.S/one()\ntest Beta.S/two()\n' > "$work/two.txt"
expect 0 "modules listed" python3 "$check" modules "$work/two.txt"
[ "$(cat "$work/out")" = "$(printf 'Alpha\nBeta')" ] && pass "both modules, once each" || fail "modules: $(cat "$work/out")"
expect 0 "filter for one module" python3 "$check" filter "$work/two.txt" Beta
[ "$(cat "$work/out")" = 'Beta\.S/two\(\)' ] && pass "module filter keeps to its module" || fail "module filter: $(cat "$work/out")"

printf 'test Mod.Suite/one()\nexclude Mod.Suite/one() both\n' > "$work/bad.txt"
expect 1 "list may not require an excluded test" python3 "$check" filter "$work/bad.txt"

# Every test of a *SampleTests suite in the sources is required or excluded.
mkdir -p "$work/Tests/Mod"
cat > "$work/Tests/Mod/S.swift" <<'EOF'
@MainActor @Suite(.serialized) struct PlainSampleTests {
    @Test func one() {}
    @Test(.enabled(if: hasSamples), arguments: [(1, 2)])
    func two(_ a: Int, b: (Int, Int)) {}
    struct Helper { func notATest() {} }
}
/// struct NotASuite in a comment
@Suite struct OtherTests {
    @Test func three() {}
}
EOF
printf 'test Mod.PlainSampleTests/one()\nexclude Mod.PlainSampleTests/two(_:b:) a reason\n' > "$work/sample-list.txt"
expect 0 "every sample suite test listed" python3 "$check" unlisted "$work/sample-list.txt" "$work/Tests"
printf 'test Mod.PlainSampleTests/one()\n' > "$work/sample-list.txt"
expect 1 "a sample suite test neither required nor excluded fails" python3 "$check" unlisted "$work/sample-list.txt" "$work/Tests"
says "unlisted test named with its labels" "Mod.PlainSampleTests/two(_:b:) is in a sample suite"

# The real list reads.
expect 0 "scripts/regression-tests.txt reads" python3 "$check" filter "$root/scripts/regression-tests.txt"
expect 0 "scripts/regression-tests.txt lists every sample suite test" python3 "$check" unlisted "$root/scripts/regression-tests.txt" "$root/Tests"

# The M5 engine summary (scripts/measure/m5/engine.zsh, SUMMARY_ONLY=1), on made-up logs: a target is
# within only when its tests exited 0, no frame failed or went uncompared, and every number printed.
engine=$root/scripts/measure/m5/engine.zsh evidence=$work/engine
mkdir -p "$evidence/raw"
t5() {  # t5 <log> <failed> <exit> [peak]: a T5 run's log, with its T6 line when a peak is given
  { echo "MEASURE T5 10 frames to full-size JPEG: $((10 - $2)) written, $2 failed, in 1.0 s; 9.00 frames a second overall, 9.00 after the raws' check (0.1 s), 9.00 first to last written, 9.00 over the slowest 9; SHA-256 known, read before in 0.1 s; RAW 9's route, of 10 frames by header RAW 9 10, in-house 0, RAW 8 0, 0 fell back to RAW 8; load 1"
    [ -z "${4:-}" ] || echo "MEASURE T6 develop to JPEG, 10 frames, RAW 9 decode tile 1024: footprint 50 MB at start, peak $4 MB (target 2000), budget 2000 MB; no gate report"
  } > "$evidence/raw/$1.log"
  echo "$3" > "$evidence/raw/$1.exit"
}
t8() {  # t8 <verdict> <exit>
  { echo "MEASURE T8 a.tif: dE2000 per pixel mean 0.0100, p95 0.00, p99 0.00, max 0.20, 0.0000% of pixels over 0.5, 99.0000% identical"
    echo "MEASURE T8 output stability against /refs: worst frame's mean dE2000 0.0100 over 5 of 5 frames (target under 0.5), $1"
  } > "$evidence/raw/t8.log"
  echo "$2" > "$evidence/raw/t8.exit"
}
summary() { env SUMMARY_ONLY=1 FRAMES=10 ROLLS=x FORMATS="0 1" TARGETS="t5 t8" zsh "$engine" "$evidence"; }
# verdict <name> <target's line> <within|MISSED>: the summary judges the target so.
verdict() {
  if grep -E "^$2" "$work/out" | grep -qE ", $3[;)]"; then pass "$1"; else fail "$1: no $3 for '$2'"; sed 's/^/      /' "$work/out" >&2; fi
}
t5 t5-x-0 0 0 1500; t5 t5-x-1 0 0 1600; t8 within 0
expect 0 "engine summary runs alone" summary
verdict "T5 within when every frame developed" "T5 x" within
verdict "T6 within with every peak" "T6 x" within
verdict "T8 within when every frame compared" "T8 " within
t5 t5-x-1 0 0
expect 0 "engine summary, a peak missing" summary
verdict "T6 missed when a peak was not printed" "T6 x" MISSED
t5 t5-x-0 2 0 1500; t5 t5-x-1 0 0 1600
expect 0 "engine summary, failed frames" summary
verdict "T5 missed when frames failed" "T5 x" MISSED
verdict "T6 missed when frames failed" "T6 x" MISSED
t5 t5-x-0 0 1 1500; t5 t5-x-1 0 1 1600
expect 0 "engine summary, failed tests" summary
verdict "T5 missed when its test failed" "T5 x" MISSED
verdict "T6 missed when a test failed" "T6 x" MISSED
t8 "INCOMPLETE 4/5" 0
expect 0 "engine summary, a frame not compared" summary
verdict "T8 missed when a frame was not compared" "T8 " MISSED
t8 within 1
expect 0 "engine summary, T8's test failed" summary
verdict "T8 missed when its test failed" "T8 " MISSED

if [ "$failures" -ne 0 ]; then
  echo "error: $failures self-test check(s) failed" >&2
  exit 1
fi
echo "all regression tooling self-tests passed"
