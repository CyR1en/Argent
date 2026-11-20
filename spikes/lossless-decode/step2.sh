#!/bin/zsh
# Argent spike, lossless-decode. Measurement script, not shipped code.
#
# Step 2: per-file, per-mode LibRaw stage timings. Warm-up 1, timed 5, median.
# Runs ./lrbench (built next to this script) on the five raw.pixls.us samples in
# ../../samples (scripts/fetch-samples.sh) in four modes each and writes step2.jsonl
# (one SUMMARY object per run) and step2.log here.
cd "$(dirname "$0")"
S=../../samples
: > step2.jsonl
: > step2.log
for f in \
  ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW \
  ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW \
  ILCE-7M4_DSC06675_FullFrame-LossLess-Compressed-Medium.ARW \
  ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW \
  ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW ; do
  for mode in "--unpack-only" "--qual 0 --mem" "--qual 1 --mem" "--qual 3 --mem"; do
    echo "=== $f $mode ===" >> step2.log
    ./lrbench $S/$f ${=mode} --iters 5 --warmup 1 --tag "$mode" >> step2.log 2>&1
    grep '^SUMMARY' step2.log | tail -1 | sed 's/^SUMMARY //' >> step2.jsonl
  done
done
echo DONE >> step2.log
