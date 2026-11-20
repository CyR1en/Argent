"""Step 0 of the fine-detail gap (docs/fine-detail-plan.md, section 4): what a DNG holds.

Lists every image directory of each DNG (IFD0, its SubIFDs and the chain) with its role, size,
photometric interpretation, samples, bits, sample format and compression, so the Enhanced DNG's
linear data (PhotometricInterpretation 34892, LinearRaw) can be told from a mosaic (32803, CFA) or a
preview kept beside it.

    python dng.py <file.dng>...
"""
import struct
import sys
from pathlib import Path

TAGS = {254: "NewSubfileType", 256: "ImageWidth", 257: "ImageLength", 258: "BitsPerSample", 259: "Compression",
        262: "PhotometricInterpretation", 277: "SamplesPerPixel", 339: "SampleFormat", 330: "SubIFDs",
        50706: "DNGVersion", 50708: "UniqueCameraModel", 50717: "WhiteLevel"}
PHOTOMETRIC = {1: "BlackIsZero", 2: "RGB", 6: "YCbCr", 32803: "CFA", 34892: "LinearRaw"}
COMPRESSION = {1: "none", 7: "JPEG", 8: "Deflate", 34892: "lossy JPEG", 52546: "JPEG XL"}
SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4, 16: 8, 17: 8, 18: 8}


def read(path):
    data = Path(path).read_bytes()
    order = {b"II": "<", b"MM": ">"}[data[:2]]
    big = struct.unpack(order + "H", data[2:4])[0] == 43

    def values(kind, count, field):
        size = SIZES.get(kind, 1) * count
        inline = 8 if big else 4
        raw = field[:size] if size <= inline else data[struct.unpack(order + ("Q" if big else "I"), field[:inline])[0]:][:size]
        fmt = {1: "B", 2: "s", 3: "H", 4: "I", 7: "B", 9: "i", 13: "I", 16: "Q", 17: "q", 18: "Q"}.get(kind)
        if fmt is None or fmt == "s":
            return raw
        return list(struct.unpack(order + fmt * count, raw))

    def ifd(offset):
        if big:
            n = struct.unpack(order + "Q", data[offset:offset + 8])[0]; entry, start = 20, offset + 8
        else:
            n = struct.unpack(order + "H", data[offset:offset + 2])[0]; entry, start = 12, offset + 2
        tags = {}
        for i in range(n):
            e = data[start + i * entry:start + (i + 1) * entry]
            if big:
                tag, kind, count = struct.unpack(order + "HHQ", e[:12]); field = e[12:20]
            else:
                tag, kind, count = struct.unpack(order + "HHI", e[:8]); field = e[8:12]
            if tag in TAGS:
                tags[TAGS[tag]] = values(kind, count, field)
        nxt_at = start + n * entry
        nxt = struct.unpack(order + ("Q" if big else "I"), data[nxt_at:nxt_at + (8 if big else 4)])[0]
        return tags, nxt

    first = struct.unpack(order + ("Q" if big else "I"), data[8:16] if big else data[4:8])[0]
    out, queue, seen = [], [("IFD0", first)], set()
    while queue:
        name, offset = queue.pop(0)
        if not offset or offset in seen:
            continue
        seen.add(offset)
        tags, nxt = ifd(offset)
        out.append((name, tags))
        for k, sub in enumerate(tags.get("SubIFDs", []) or []):
            queue.append((f"{name}.SubIFD{k}", sub))
        if nxt:
            queue.append((f"IFD{len([o for o in out if o[0].startswith('IFD') and '.' not in o[0]])}", nxt))
    return out


def first(v):
    return v[0] if isinstance(v, list) and v else v


if __name__ == "__main__":
    for path in sys.argv[1:]:
        print(path)
        for name, t in read(path):
            role = "main" if first(t.get("NewSubfileType", 0)) == 0 else f"subfile type {first(t.get('NewSubfileType'))}"
            photometric = first(t.get("PhotometricInterpretation"))
            compression = first(t.get("Compression"))
            print(f"  {name}: {role}, {first(t.get('ImageWidth'))} x {first(t.get('ImageLength'))}, "
                  f"{PHOTOMETRIC.get(photometric, photometric)}, {first(t.get('SamplesPerPixel'))} samples of "
                  f"{t.get('BitsPerSample')} bits, format {t.get('SampleFormat', [1])}, "
                  f"compression {COMPRESSION.get(compression, compression)}"
                  + (f", DNG {t['DNGVersion']}" if "DNGVersion" in t else ""))
