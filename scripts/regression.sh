#!/bin/bash
# Runs the real-RAW regression suite (docs/ci-regression.md): verifies the CC0 samples against
# scripts/samples.manifest without touching the network, runs exactly the tests
# scripts/regression-tests.txt requires, and fails unless every one of them ran and passed.
# A missing or corrupt sample fails here, before any test, instead of skipping the suites.
#
#     scripts/regression.sh [swift test options, e.g. --scratch-path DIR or --skip-build]
#
# ARGENT_REGRESSION_OUT names the folder for the report and the log (default
# $TMPDIR/argent-regression). Every ARGENT_* variable is unset for the run, so no opt-in
# measurement suite or stand-in input joins it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# The folder and manifest the tests use, whatever the environment says.
ARGENT_SAMPLES_DIR=$root/samples ARGENT_SAMPLES_MANIFEST=$root/scripts/samples.manifest scripts/fetch-samples.sh --check

# Every test of a sample suite is required or excluded.
python3 scripts/regression.py unlisted scripts/regression-tests.txt Tests

out=${ARGENT_REGRESSION_OUT:-${TMPDIR:-/tmp}/argent-regression}
mkdir -p "$out"
modules=$(python3 scripts/regression.py modules scripts/regression-tests.txt)
# Only this script's own reports and log, so the folder may hold other files.
for module in $modules; do rm -f "$out/$module.xml" "$out/$module-swift-testing.xml"; done
rm -f "$out/log.txt"

for name in $(env | sed -n 's/^\(ARGENT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$name"; done

# One test module at a time: SwiftPM runs each in its own process, and each would overwrite the
# other's report.
status=0 reports=()
for module in $modules; do
  filter=$(python3 scripts/regression.py filter scripts/regression-tests.txt "$module")
  swift test "$@" --filter "$filter" --xunit-output "$out/$module.xml" 2>&1 | tee -a "$out/log.txt" || status=$?
  reports+=("$out/$module-swift-testing.xml")
done
python3 scripts/regression.py check scripts/regression-tests.txt "$out/log.txt" "${reports[@]}" || status=1
if [ "$status" -ne 0 ]; then
  echo "error: real-RAW regression suite failed; report and log in $out" >&2
fi
exit "$status"
