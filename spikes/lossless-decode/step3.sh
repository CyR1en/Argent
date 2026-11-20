#!/bin/zsh
# Argent spike, lossless-decode. Measurement script, not shipped code.
#
# Step 3: N concurrent lrbench processes, N = 1 2 4 8 10, through parallel.py, in
# three configurations:
#   L-unpack : lossless L, open_file + unpack only
#   L-proc   : lossless L, open_file + unpack + dcraw_process(user_qual 0, linear)
#   U-unpack : uncompressed, open_file + unpack only (isolates decompression cost)
# Expects ./lrbench next to this script, the samples in ../../samples and the project
# venv in ../../.venv. Writes step3.jsonl here.
cd "$(dirname "$0")"
S=../../samples
L=$S/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW
U=$S/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW
PY=../../.venv/bin/python
: > step3.jsonl
for cfg in "L-unpack|$L|--unpack-only" "L-proc|$L|--qual 0" "U-unpack|$U|--unpack-only"; do
  name=${cfg%%|*}; rest=${cfg#*|}; file=${rest%%|*}; args=${rest#*|}
  for N in 1 2 4 8 10; do
    echo -n "{\"cfg\":\"$name\",\"res\":" >> step3.jsonl
    $PY parallel.py ./lrbench "$file" $N ${=args} --iters 5 --warmup 1 --tag "$name-N$N" | tr -d '\n' >> step3.jsonl
    echo "}" >> step3.jsonl
    sleep 2
  done
done
echo DONE >> step3.jsonl
