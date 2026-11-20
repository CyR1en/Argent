#!/usr/bin/env python3
"""Writes the develop-memory rolls (docs/manual-development-validation.md, "Develops started with the
frame view open").

The 30-frame memory roll is DecoderSwitchMeasureTests.makeRolls's `mixed`: the M2 gate's 19 files (the
five CC0 samples in samples/, one in each raw mode, and the 14 photographyblog frames in
references/corpus/photographyblog-a7iv) and eleven copies of the CC0 lossless L sample with their Exif
ISO rewritten to 100 to 6400. It is written twice under fresh identities, `mixed-a` and `mixed-b`, and a
three-frame `smoke` roll is written for trying the tools. A fresh identity is a copy with trailing bytes
of its own: the library keys working edits by the raw's SHA-256, so two rolls of identical copies would
share their edits. Each roll's SHA-256 values are written beside it.

    make-rolls.py REPOSITORY OUT
"""
import hashlib
import sys
from pathlib import Path

COPY_ISOS = [100, 160, 200, 320, 400, 500, 640, 800, 1600, 3200, 6400]
LOSSLESS = "samples/ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW"
SMOKE = ["ILCE-7M4_DSC06673_FullFrame-Raw-Uncompressed.ARW",
         "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW",
         "ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW"]


def with_iso(data, iso):
    """DecoderSwitchMeasureTests.copyRaw: the Exif ISOSpeedRatings (SHORT) and
    RecommendedExposureIndex (LONG) of a little-endian TIFF raw set to `iso`."""
    data = bytearray(data)

    def u16(o):
        return data[o] | data[o + 1] << 8

    def u32(o):
        return u16(o) | u16(o + 2) << 16

    def entry(ifd, tag):
        return next((ifd + 2 + 12 * i for i in range(u16(ifd)) if u16(ifd + 2 + 12 * i) == tag), None)

    exif = u32(entry(u32(4), 0x8769) + 8)
    e = entry(exif, 0x8827)
    if e is not None and u16(e + 2) == 3:
        data[e + 8:e + 10] = min(iso, 65535).to_bytes(2, "little")
    e = entry(exif, 0x8832)
    if e is not None and u16(e + 2) == 4:
        data[e + 8:e + 12] = iso.to_bytes(4, "little")
    return bytes(data)


def gate_files(repository):
    """The M2 gate's files, as FrameViewMeasureTests.gateFiles sorts them, each checked against the
    SHA-256 recorded for it: the samples' in scripts/samples.manifest, the photographyblog frames' in
    photographyblog-a7iv.sha256 beside this script."""
    files = [p for folder in ["samples", "references/corpus/photographyblog-a7iv"]
             for p in (repository / folder).iterdir() if p.suffix.lower() == ".arw"]
    expected = {}
    for line in (repository / "scripts/samples.manifest").read_text().splitlines():
        if line and not line.startswith("#"):
            digest, _, name, _ = line.split()
            expected[name] = digest
    for line in (Path(__file__).parent / "photographyblog-a7iv.sha256").read_text().splitlines():
        if line and not line.startswith("#"):
            digest, name = line.split()
            expected[name] = digest
    for p in files:
        if hashlib.sha256(p.read_bytes()).hexdigest() != expected.get(p.name):
            sys.exit(f"error: {p} is not the recorded file")
    return sorted(files, key=lambda p: str(p))


def write_roll(folder, sources, tag):
    folder.mkdir(parents=True, exist_ok=False)
    lines = []
    for name, data in sources:
        data = data + tag
        (folder / name).write_bytes(data)
        lines.append(f"{hashlib.sha256(data).hexdigest()}  {name}")
    (folder.parent / f"{folder.name}.sha256").write_text("\n".join(lines) + "\n")
    print(f"{folder.name}: {len(sources)} frames")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: make-rolls.py REPOSITORY OUT")
    repository, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    gate = gate_files(repository)
    if len(gate) != 19:
        sys.exit(f"error: the M2 gate needs 19 files (5 samples, 14 photographyblog frames), found {len(gate)}")
    lossless = (repository / LOSSLESS).read_bytes()
    mixed = [(p.name, p.read_bytes()) for p in gate]
    mixed += [(f"DSC06674-ISO{iso:05d}.ARW", with_iso(lossless, iso)) for iso in COPY_ISOS]
    assert len(mixed) == 30
    for roll in ["mixed-a", "mixed-b"]:
        write_roll(out / roll, mixed, f"argent {roll}".encode())
    write_roll(out / "smoke", [(n, (repository / "samples" / n).read_bytes()) for n in SMOKE], b"argent smoke")


if __name__ == "__main__":
    main()
