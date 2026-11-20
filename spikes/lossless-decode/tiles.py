#!/usr/bin/env python3
# Argent spike, lossless-decode. Measurement prototype, not shipped code.
#
# tiles.py walks every IFD and SubIFD of an ARW and prints the tile geometry and
# compression tags, which is how the 140 tiles of the L stream and the 70 and 35
# YCbCr tiles of M and S were found. Run it on one tiled file at a time: it prints the
# raw SubIFD, which is the result, then stops with a struct.error on the IFD after it.
# On the uncompressed file it spends minutes in a large strip tag first. Standard
# library only.
"""Dump TIFF tile geometry (tags 0x142/0x143/0x144/0x145, compression, bps, samples) for every IFD/SubIFD of an ARW."""
import struct, sys
TAGS = {0x100:"ImageWidth",0x101:"ImageLength",0x102:"BitsPerSample",0x103:"Compression",0x106:"Photometric",0x115:"SamplesPerPixel",0x142:"TileWidth",0x143:"TileLength",0x144:"TileOffsets",0x145:"TileByteCounts",0x14a:"SubIFDs",0x111:"StripOffsets",0x117:"StripByteCounts",0x116:"RowsPerStrip"}
SZ = {1:1,2:1,3:2,4:4,5:8,6:1,7:1,8:2,9:4,10:8,11:4,12:8,13:4,16:8}
def read_ifd(f, off, en, depth=0, name="IFD"):
    f.seek(off); n = struct.unpack(en+"H", f.read(2))[0]
    out = {}; subs = []
    for i in range(n):
        tag, typ, cnt = struct.unpack(en+"HHI", f.read(8)); raw = f.read(4)
        size = SZ.get(typ,1)*cnt
        if size > 64*1024*1024: continue
        if size > 4 and struct.unpack(en+"I", raw)[0] + size > fsize: continue
        if size <= 4: data = raw[:size]
        else:
            off2 = struct.unpack(en+"I", raw)[0]; cur = f.tell(); f.seek(off2); data = f.read(size); f.seek(cur)
        fmt = {3:"H",4:"I",8:"h",9:"i"}.get(typ)
        vals = list(struct.unpack(en+fmt*cnt, data)) if fmt else data
        if tag in TAGS: out[TAGS[tag]] = vals if (fmt and cnt <= 8) else (f"{cnt} values, first {vals[:3]}" if fmt else vals[:16])
        if tag == 0x14a: subs = vals
    keep = {k:v for k,v in out.items() if k != "SubIFDs"}
    if "TileWidth" in out or "Compression" in out: print("  "*depth + f"{name} @0x{off:x}: {keep}")
    for s in subs: read_ifd(f, s, en, depth+1, "SubIFD")
    nxt = struct.unpack(en+"I", f.read(4))[0]
    return nxt
for p in sys.argv[1:]:
    print(p.split('/')[-1])
    import os; fsize = os.path.getsize(p)
    with open(p,"rb") as f:
        h = f.read(8); en = "<" if h[:2]==b"II" else ">"; off = struct.unpack(en+"I", h[4:8])[0]
        k = 0
        while off and k < 8:
            off = read_ifd(f, off, en, 0, f"IFD{k}"); k += 1
