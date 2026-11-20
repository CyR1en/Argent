"""Dump Sony lens-correction tags (0x7031..0x7037) from the raw SubIFD, plus lens info from Exif.

Usage: python -I tags.py FILE...
A minimal TIFF walker written for this exploration; reads only.
"""
import struct
import sys

TYPES = {1: ('B', 1), 2: ('s', 1), 3: ('H', 2), 4: ('I', 4), 5: ('II', 8), 6: ('b', 1), 7: ('B', 1),
         8: ('h', 2), 9: ('i', 4), 10: ('ii', 8), 13: ('I', 4)}


class TIFF:
    def __init__(self, path):
        self.f = open(path, 'rb')
        self.data = self.f.read()
        self.e = '<' if self.data[:2] == b'II' else '>'
        self.first = struct.unpack(self.e + 'I', self.data[4:8])[0]

    def ifd(self, off):
        n = struct.unpack(self.e + 'H', self.data[off:off + 2])[0]
        out = {}
        for i in range(n):
            b = off + 2 + 12 * i
            tag, typ, cnt = struct.unpack(self.e + 'HHI', self.data[b:b + 8])
            out[tag] = (typ, cnt, b + 8)
        nxt = struct.unpack(self.e + 'I', self.data[off + 2 + 12 * n:off + 6 + 12 * n])[0]
        return out, nxt

    def values(self, entry):
        typ, cnt, at = entry
        if typ not in TYPES:
            return None
        fmt, size = TYPES[typ]
        total = size * cnt
        if total > 4:
            at = struct.unpack(self.e + 'I', self.data[at:at + 4])[0]
        raw = self.data[at:at + total]
        if typ == 2:
            return raw.split(b'\0')[0].decode('latin1')
        if typ in (5, 10):
            v = struct.unpack(self.e + fmt[0] * (2 * cnt), raw)
            return [v[2 * i] / v[2 * i + 1] if v[2 * i + 1] else 0 for i in range(cnt)]
        return list(struct.unpack(self.e + fmt * cnt, raw))


def dump(path):
    t = TIFF(path)
    ifd0, _ = t.ifd(t.first)
    model = t.values(ifd0[0x0110]) if 0x0110 in ifd0 else ''
    orient = t.values(ifd0[0x0112])[0] if 0x0112 in ifd0 else 1
    info = {'model': model, 'orientation': orient}
    if 0x8769 in ifd0:
        exif, _ = t.ifd(t.values(ifd0[0x8769])[0])
        for tag, name in [(0xA434, 'lens'), (0x920A, 'focal'), (0x829D, 'f'), (0x8827, 'iso')]:
            if tag in exif:
                v = t.values(exif[tag])
                info[name] = v if isinstance(v, str) else v[0]
    print(path.split('/')[-1], info)
    for off in t.values(ifd0[0x014A]) if 0x014A in ifd0 else []:
        sub, _ = t.ifd(off)
        if t.values(sub.get(0x00FE, (4, 1, 0)))[0] != 0 if 0x00FE in sub else False:
            continue
        for tag in range(0x7030, 0x7040):
            if tag in sub:
                typ, cnt, _ = sub[tag]
                print('  0x%04X type %d count %d:' % (tag, typ, cnt), t.values(sub[tag]))
        for tag in (0xC61F, 0xC620, 0x7038, 0x0100, 0x0101):
            if tag in sub:
                print('  0x%04X' % tag, t.values(sub[tag]))


if __name__ == "__main__":
  for p in sys.argv[1:]:
    dump(p)
