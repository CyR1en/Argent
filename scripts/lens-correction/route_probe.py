#!/usr/bin/env python3
"""Summarize LensMeasureTests/routes without fitting or reading image data."""
import argparse
import csv
import math
from pathlib import Path


SCHEMAS = {
    "ROUTE": "frame pair ring patches green_median_px green_p95_px radial_px red_green_p95_px blue_green_p95_px",
    "ROUTE_META": "frame setting knots",
    "ROUTE_DECODE": "frame pair width height milliseconds",
    "ROUTE_SKIP": "frame reason",
    "ROUTE_SUMMARY": "frame pair patches green_median_px green_p95_px",
    "ROUTE_FIT": "frame pair patches curve_gain curve_rms_px fitted_rms_px predicted_median_px",
    "ROUTE_EDGE": "frame pair edge correlation",
    "ROUTE_DETAIL": "frame pair ring patches energy_ratio stationary_patches stationary_energy_ratio noise_patches noise_ratio",
    "ROUTE_TONE": "frame pair ring patches brightness_ratio",
}


def parse(lines):
    rows = []
    for line in lines:
        cells = line.rstrip("\n").split("\t")
        if cells[0] not in SCHEMAS:
            continue
        keys = SCHEMAS[cells[0]].split()
        if len(cells) != len(keys) + 1:
            raise ValueError(f"Malformed {cells[0]} row: {line!r}")
        rows.append(dict(record=cells[0], **dict(zip(keys, cells[1:]))))
    return rows


def verdicts(rows):
    result = []
    for meta in (r for r in rows if r["record"] == "ROUTE_META"):
        frame = meta["frame"]
        own = [r for r in rows if r["frame"] == frame]

        def find(kind, pair):
            return next((r for r in own if r["record"] == kind and r.get("pair") == pair), None)

        on = find("ROUTE_SUMMARY", "raw9-on/raw9-off")
        fit = find("ROUTE_FIT", "raw9-on/raw9-off")
        off = find("ROUTE_SUMMARY", "raw9-off/inhouse-off")
        extent = find("ROUTE_DECODE", "raw9-off")
        reference = find("ROUTE_DECODE", "inhouse-off")
        edges = [float(r["correlation"]) for r in own
                 if r["record"] == "ROUTE_EDGE" and r["pair"] == "raw9-off/inhouse-off"]
        if on is None:
            result.append(f"{frame}\tRAW9 unsupported; off verdict unavailable")
            continue
        shift = float(on["green_median_px"])
        if fit and float(fit["predicted_median_px"]) > 0.05:
            matches = (float(fit["curve_rms_px"]) <= 1.0
                       and 0.8 <= float(fit["curve_gain"]) <= 1.2)
            curve = (f"fits file curve {'yes' if matches else 'no'}, "
                     f"rms {float(fit['curve_rms_px']):.4f} px, gain {float(fit['curve_gain']):.4f}")
        else:
            curve = "file curve flat or unusable"
        correction = "yes" if math.isfinite(shift) and shift > 0.05 else "no"
        if meta["setting"] == "1":
            curve += f", setting 1 corrected {correction}"
        full = all(r and sorted([int(r["width"]), int(r["height"])]) == [4672, 7008] for r in [extent, reference])
        median = float(off["green_median_px"]) if off else math.nan
        passed = bool(off and int(off["patches"]) > 0 and median <= 0.10 and full)
        state = "unavailable" if off is None or reference is None else ("PASS" if passed else "FAIL")
        edge = min(edges) if len(edges) == 4 and all(map(math.isfinite, edges)) else math.nan
        size = f"{extent['width']}x{extent['height']}" if extent else "unavailable"
        result.append(f"{frame}\tRAW9 on-off {shift:.4f} px, {curve}; "
                      f"off {state}, median {median:.4f} px, "
                      f"extent {size}, edge min {edge:.6f}")
    return result


def self_test():
    lines = [
        "ROUTE_META\tsynthetic\t1\t0,16",
        "ROUTE_DECODE\tsynthetic\traw9-off\t7008\t4672\t20",
        "ROUTE_DECODE\tsynthetic\tinhouse-off\t7008\t4672\t10",
        "ROUTE_SUMMARY\tsynthetic\traw9-on/raw9-off\t150\t2.0\t3.0",
        "ROUTE_SUMMARY\tsynthetic\traw9-off/inhouse-off\t150\t0.025\t0.04",
        "ROUTE_FIT\tsynthetic\traw9-on/raw9-off\t150\t1\t0.02\t0.02\t2",
    ] + [f"ROUTE_EDGE\tsynthetic\traw9-off/inhouse-off\t{e}\t0.999" for e in ["top", "bottom", "left", "right"]]
    rows = parse(lines)
    text = verdicts(rows)[0]
    assert "fits file curve yes" in text and "setting 1 corrected yes" in text
    assert "off PASS, median 0.0250 px, extent 7008x4672" in text
    rows[4]["green_median_px"] = "0.25"
    assert "off FAIL, median 0.2500 px" in verdicts(rows)[0]
    rows[4]["green_median_px"] = "0.025"
    rows[1]["width"] = "7006"
    assert "off FAIL" in verdicts(rows)[0]
    for r in [rows[1], rows[2]]:
        r.update(width="4672", height="7008")
    assert "off PASS" in verdicts(rows)[0]
    rows[5]["curve_gain"] = "0"
    assert "fits file curve no" in verdicts(rows)[0]
    rows[3]["green_median_px"] = "0"
    assert "setting 1 corrected no" in verdicts(rows)[0]
    assert "off unavailable" in verdicts(rows[:4] + rows[5:])[0]
    print("self-test PASS: known shifts, extent loss, curve mismatch, and no correction")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path, nargs="?")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.log is None:
        parser.error("provide the test output file or --self-test")
    rows = parse(args.log.read_text().splitlines())
    if not any(r["record"] == "ROUTE_META" for r in rows):
        parser.error("no route measurements found")
    columns = list(dict.fromkeys(["record"] + [k for schema in SCHEMAS.values() for k in schema.split()]))
    with args.log.with_name("routes.csv").open("w", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)
    print("Frame\tVerdict (median shifts; curve tolerance 1 px RMS and gain 0.8 to 1.2)")
    print("\n".join(verdicts(rows)))


if __name__ == "__main__":
    main()
