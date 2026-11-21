# lossless-decode

Does a LibRaw path, or the format itself, beat Apple's 415 to 560 ms lossless L decode? Measured
2026-10-05 and 2026-10-06 on the M4 (macOS 27.0, Apple clang 21, LibRaw 0.22.2).
The results below informed Argent's in-house tile decoder.

| File | What it is |
| --- | --- |
| `lrbench.cpp` | times LibRaw's open, unpack, copy, `dcraw_process`, `dcraw_make_mem_image`; `--dump` writes the unpacked buffer, `--green` the mean green |
| `parallel.py` | N lrbench processes on one file, aggregate frames a second |
| `tiles.py` | prints an ARW's tile geometry and compression tags (then stops with a `struct.error` on the next IFD; do not point it at the uncompressed file) |
| `tiledec.cpp` | from-spec (ITU-T T.81, TIFF 6.0) tile-parallel decoder for lossless L, compared with the LibRaw dump; no LibRaw or dcraw code |
| `step2.sh`, `step3.sh` | per-mode LibRaw stage timings; N-process scaling (run on an idle machine) |

Build. LibRaw is not vendored: fetch the 0.22.2 tarball from libraw.org (sha256
`de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa`) next to these files.

    tar xzf LibRaw-0.22.2.tar.gz
    (cd LibRaw-0.22.2 && make -f Makefile.dist -j10 lib/libraw.a CC=clang CXX=clang++ 'CFLAGS=-O3 -I. -w -DUSE_ZLIB -DLIBRAW_NOTHREADS')
    clang++ -O3 -std=c++17 -ILibRaw-0.22.2 lrbench.cpp LibRaw-0.22.2/lib/libraw.a -lz -o lrbench
    clang++ -O3 -std=c++17 tiledec.cpp -o tiledec

Run (samples from `scripts/fetch-samples.sh`):

    L=../../samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW
    ./lrbench $L --unpack-only --dump libraw_L.raw
    ./tiledec $L --threads 10 --iters 5 --warmup 1 --compare libraw_L.raw

The dump is 73 MB (7168 by 5120 uint16). tiledec prints an `ITER` line per run and a `SUMMARY` JSON
line; `--threads 1` gives the single-core figure, and `--out` writes the mosaic that
`InHouseDecoderMeasureTests/tilesMatchTheSpike` compares against.

Result: LibRaw unpacks lossless L in 310 to 333 ms on one thread, walking the 140 independent tiles in
sequence. tiledec decodes them in 200 / 54 / 32 ms on 1 / 4 / 10 threads (31.1 ms re-run), 0
mismatches over 36,700,160 samples. The budget is reachable because of the format, not LibRaw. tiledec
refuses the YCbCr M and S streams and is not hardened.
