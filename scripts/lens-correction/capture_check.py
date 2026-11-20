#!/usr/bin/env python3
"""List the Appendix F captures, reject clipped or uneven flats, and print what is missing.

Layout, under the folder given:
  <lens>/flats/*.ARW   <lens>/charts/*.ARW   real/*.ARW
where <lens> starts with viltrox, sirui or tamron. Exit status 0 means nothing is missing.
"""
import argparse
import math
import mmap
import struct
import sys
from collections import Counter
from pathlib import Path

import numpy as np

FLATS = {
    "viltrox": {50: [1.4, 1.6, 2, 2.8, 4, 5.6, 8, 11]},
    "sirui": {35: [1.4, 2, 2.8, 4, 5.6, 8, 11]},
    "tamron": {f: [2.8, 4, 5.6, 8] for f in (28, 35, 42, 50, 75)},
}
CHARTS = {
    "viltrox": {50: [1.4, 5.6]},
    "sirui": {35: [1.4, 5.6]},
    "tamron": {f: [2.8, 5.6] for f in (28, 50, 75)},
}
FLAT_REPEATS = 4        # per setting, with Shading Comp. on Auto, and again with it Off
CHART_REPEATS = 6       # per setting: three at about 1 m and three at 5 m or more
REAL_FRAMES = 13
LEVEL = (0.25, 0.75)    # the brightest channel's share of its range at the centre
CLIPPED = 1e-4          # share of samples at the white level
UNEVEN = 0.05           # largest difference between mirrored blocks, inside 80% of the half diagonal

SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 8: 2, 9: 4, 10: 8, 13: 4}
CODES = {1: "B", 3: "H", 4: "I", 5: "I", 7: "B", 8: "h", 9: "i", 10: "i", 13: "I"}


def read_ifd(data, offset):
    tags = {}
    for i in range(struct.unpack_from("<H", data, offset)[0]):
        tag, kind, count, value = struct.unpack_from("<HHI4s", data, offset + 2 + 12 * i)
        if kind not in SIZES:
            continue
        size = SIZES[kind] * count
        at = struct.unpack("<I", value)[0]
        raw = value[:size] if size <= 4 else data[at:at + size]
        if kind == 2:
            tags[tag] = raw.split(b"\0")[0].decode("ascii", "replace")
        elif kind in (5, 10):
            pairs = struct.unpack(f"<{2 * count}{CODES[kind]}", raw)
            tags[tag] = tuple(a / b if b else 0.0 for a, b in zip(pairs[::2], pairs[1::2]))
        else:
            tags[tag] = struct.unpack(f"<{count}{CODES[kind]}", raw)
    return tags


def read_frame(path, pixels):
    """The frame's settings, and with `pixels` its raw samples where the file is uncompressed."""
    with open(path, "rb") as file, mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as data:
        if data[:4] != b"II*\0":
            raise ValueError("not a little-endian TIFF")
        ifd0 = read_ifd(data, struct.unpack_from("<I", data, 4)[0])
        exif = read_ifd(data, ifd0[0x8769][0])
        raw = next(ifd for ifd in map(lambda at: read_ifd(data, at), ifd0[0x014A])
                   if ifd.get(0x00FE, (0,))[0] == 0 and 0x0103 in ifd)
        frame = dict(
            f_number=exif[0x829D][0], focal=exif[0x920A][0], iso=exif[0x8827][0],
            width=raw[0x0100][0], height=raw[0x0101][0], uncompressed=raw[0x0103][0] == 1,
            shading={256: "off", 257: "auto", 272: "auto"}.get(raw.get(0x7031, (0,))[0], "unknown"),
            black=raw.get(0x7310, (512,))[0], white=raw.get(0x787F, (16383,))[0], samples=None)
        if pixels and frame["uncompressed"]:
            frame["samples"] = np.frombuffer(
                data, "<u2", frame["width"] * frame["height"], raw[0x0111][0]
            ).reshape(frame["height"], frame["width"]).copy()
        return frame


def flat_metrics(samples, black, white):
    """The centre's level, the clipped share, and the largest mirrored difference."""
    planes = [samples[y::2, x::2] for y in (0, 1) for x in (0, 1)]
    rows, columns = planes[0].shape[0] // 16, planes[0].shape[1] // 24
    means = [plane[:16 * rows, :24 * columns].reshape(16, rows, 24, columns).mean(axis=(1, 3)) - black
             for plane in planes]
    level = max(float(mean[6:10, 9:15].mean()) for mean in means) / (white - black)
    clipped = float((samples >= white).mean())
    field = sum(means)
    y, x = np.mgrid[0:16, 0:24]
    inside = np.hypot((y - 7.5) / 8, (x - 11.5) / 12) <= 0.8 * math.sqrt(2)
    uneven = max(float((np.abs(field - mirror) / ((field + mirror) / 2))[inside].max())
                 for mirror in (field[::-1], field[:, ::-1], field[::-1, ::-1]))
    return level, clipped, uneven


def nearest(value, choices, tolerance, log=False):
    distance = (lambda c: abs(math.log2(value / c))) if log else (lambda c: abs(value - c))
    best = min(choices, key=distance)
    return best if value > 0 and distance(best) <= tolerance else None


def setting(frame, table):
    focal = nearest(frame["focal"], table, 2)
    f_number = nearest(frame["f_number"], table[focal], 0.08, log=True) if focal else None
    return (focal, f_number) if f_number else None


def flat_problem(frame):
    if not frame["uncompressed"]:
        return "not uncompressed raw"
    if frame["width"] < 6000:
        return "not full frame"
    if frame["iso"] != 100:
        return f"ISO {frame['iso']}, not 100"
    if frame["shading"] == "unknown":
        return "Shading Comp. setting not readable"
    level, clipped, uneven = flat_metrics(frame["samples"], frame["black"], frame["white"])
    if clipped > CLIPPED:
        return f"clipped, {clipped:.2%} of samples at white"
    if not LEVEL[0] <= level <= LEVEL[1]:
        return f"level {level:.2f} of range, wanted near 0.50"
    if uneven > UNEVEN:
        return f"uneven, mirrored blocks differ by {uneven:.1%}"
    return None


def check(root):
    missing = 0
    for lens, table in FLATS.items():
        folders = [p for p in sorted(root.iterdir()) if p.is_dir() and p.name.lower().startswith(lens)]
        flats, charts = Counter(), Counter()
        for kind, counts in (("flats", flats), ("charts", charts)):
            for path in sorted(q for p in folders for q in (p / kind).glob("*.ARW")):
                try:
                    frame = read_frame(path, pixels=kind == "flats")
                    key = setting(frame, FLATS[lens] if kind == "flats" else CHARTS[lens])
                    problem = None if key else (
                        f"unexpected setting, {frame['focal']:g} mm f/{frame['f_number']:g}")
                    if key and kind == "flats":
                        problem = flat_problem(frame)
                        key += (frame["shading"],)
                except (KeyError, ValueError, StopIteration, struct.error) as error:
                    problem = f"unreadable, {error!r}"
                if problem:
                    print(f"REJECT\t{lens}\t{kind}\t{path.name}\t{problem}")
                else:
                    counts[key] += 1
        chart_total = sum(charts.values())
        print(f"FOUND\t{lens}\t{sum(flats.values())} good flats, {chart_total} chart frames")
        for focal, f_numbers in table.items():
            for f_number in f_numbers:
                wanted = ["auto"] + (["off"] if f_number in (min(f_numbers), 8) else [])
                for shading in wanted:
                    short = FLAT_REPEATS - flats[focal, f_number, shading]
                    if short > 0:
                        missing += short
                        print(f"MISSING\t{lens}\tflats\t{focal} mm f/{f_number:g} "
                              f"Shading Comp. {shading}\t{short} more")
        chart_settings = [(focal, f) for focal, fs in CHARTS[lens].items() for f in fs]
        for focal, f_number in chart_settings:
            short = CHART_REPEATS - charts[focal, f_number]
            if short > 0:
                missing += short
                print(f"MISSING\t{lens}\tcharts\t{focal} mm f/{f_number:g}\t{short} more")
        if chart_total <= CHART_REPEATS * len(chart_settings) and chart_total > 0:
            missing += 1
            print(f"MISSING\t{lens}\tcharts\tthe frame with the coloured paper\t1 more")
    real = len(list((root / "real").glob("*.ARW")))
    print(f"FOUND\treal\t{real} frames")
    if real < REAL_FRAMES:
        missing += REAL_FRAMES - real
        print(f"MISSING\treal\tfringe frames\t{REAL_FRAMES - real} more")
    print("COMPLETE" if missing == 0 else f"INCOMPLETE\t{missing} frames missing")
    return missing == 0


def self_test():
    y, x = np.mgrid[0:1600, 0:2400]
    falloff = 1 - 0.6 * (((y - 799.5) / 800) ** 2 + ((x - 1199.5) / 1200) ** 2) / 2
    good = (512 + 8000 * falloff).astype("<u2")
    level, clipped, uneven = flat_metrics(good, 512, 16383)
    assert 0.45 < level < 0.55 and clipped == 0 and uneven < 0.001, (level, clipped, uneven)
    tilted = (512 + 8000 * falloff * (1 + 0.1 * (x - 1200) / 1200)).astype("<u2")
    assert flat_metrics(tilted, 512, 16383)[2] > UNEVEN
    bright = np.minimum(512 + 20000 * falloff, 16383).astype("<u2")
    assert flat_metrics(bright, 512, 16383)[1] > CLIPPED
    frame = dict(focal=41.0, f_number=5.6)
    assert setting(frame, FLATS["tamron"]) == (42, 5.6)
    assert setting(dict(focal=50.0, f_number=1.8), FLATS["viltrox"]) is None
    sample = Path("samples/ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW")
    if sample.exists():
        frame = read_frame(sample, pixels=True)
        assert frame["uncompressed"] and frame["samples"].shape == (frame["height"], frame["width"])
        assert frame["shading"] in ("off", "auto") and frame["iso"] > 0 and frame["f_number"] > 0
        assert frame["black"] < int(frame["samples"].mean()) < frame["white"]
        print(f"sample\t{frame['width']}x{frame['height']}\tISO {frame['iso']}\t"
              f"{frame['focal']:g} mm f/{frame['f_number']:g}\tShading Comp. {frame['shading']}")
    else:
        print("sample\tskipped, not present")
    print("self-test passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("captures", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    arguments = parser.parse_args()
    if arguments.self_test:
        self_test()
    elif arguments.captures and arguments.captures.is_dir():
        sys.exit(0 if check(arguments.captures) else 1)
    else:
        parser.error("give the captures folder, or --self-test")


if __name__ == "__main__":
    main()
