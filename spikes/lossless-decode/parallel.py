#!/usr/bin/env python3
# Argent spike, lossless-decode. Measurement prototype, not shipped code.
#
# parallel.py launches N lrbench processes on one file at once and reports the
# aggregate frames per second, to see how LibRaw's unpack scales across processes.
# step3.sh drives it. It needs only the standard library.
"""Run N concurrent lrbench processes on one file and report aggregate throughput.

usage: parallel.py <lrbench> <file> <N> [lrbench args...]

Each process does its own warm-up frame(s) plus timed iterations. Aggregate frames per
second counts every frame each process decoded (warm-up included, they are real decodes)
over the wall time from launching the first process to the exit of the last one.
A second figure, fps_timed, counts only timed frames over the span from the earliest
timed-iteration start to the latest timed-iteration end across processes (CLOCK_REALTIME).
"""
import json
import subprocess
import sys
import time


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    lrbench, path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    extra = sys.argv[4:]
    iters = 5
    warmup = 1
    if "--iters" in extra:
        iters = int(extra[extra.index("--iters") + 1])
    if "--warmup" in extra:
        warmup = int(extra[extra.index("--warmup") + 1])
    t0 = time.monotonic()
    procs = [
        subprocess.Popen([lrbench, path] + extra, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for _ in range(n)
    ]
    outs = [p.communicate() for p in procs]
    wall = time.monotonic() - t0
    summaries = []
    for (out, err), p in zip(outs, procs):
        s = None
        for line in out.splitlines():
            if line.startswith("SUMMARY "):
                s = json.loads(line[len("SUMMARY "):])
        if s is None:
            print("process failed:", p.returncode, err[-500:], file=sys.stderr)
            continue
        summaries.append(s)
    frames_total = n * (iters + warmup)
    frames_timed = n * iters
    t_first = min(s["t_first"] for s in summaries)
    t_last = max(s["t_last"] for s in summaries)
    med_unpack = sorted(s["med_unpack_ms"] for s in summaries)
    med_process = sorted(s["med_process_ms"] for s in summaries)
    med_total = sorted(s["med_total_ms"] for s in summaries)
    res = {
        "n": n,
        "file": path,
        "args": extra,
        "wall_s": round(wall, 3),
        "frames_total": frames_total,
        "fps_all": round(frames_total / wall, 3),
        "timed_span_s": round(t_last - t_first, 3),
        "fps_timed": round(frames_timed / (t_last - t_first), 3) if t_last > t_first else None,
        "per_proc_med_unpack_ms": med_unpack,
        "per_proc_med_process_ms": med_process,
        "per_proc_med_total_ms": med_total,
        "median_of_medians_unpack_ms": med_unpack[len(med_unpack) // 2],
        "median_of_medians_total_ms": med_total[len(med_total) // 2],
        "errors": [s["err_text"] for s in summaries if s["err"]],
    }
    print(json.dumps(res))


if __name__ == "__main__":
    main()
