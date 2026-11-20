"""Extract IFD JPEGs (offset 0x0201, length 0x0202) from an ARW. Usage: jpeg.py ARW OUTPREFIX"""
import struct, sys
data = open(sys.argv[1], 'rb').read()
e = '<' if data[:2] == b'II' else '>'
off = struct.unpack(e + 'I', data[4:8])[0]
k = 0
while off and k < 8:
    n = struct.unpack(e + 'H', data[off:off+2])[0]
    tags = {}
    for i in range(n):
        b = off + 2 + 12*i
        tag, typ, cnt = struct.unpack(e + 'HHI', data[b:b+8])
        tags[tag] = struct.unpack(e + 'I', data[b+8:b+12])[0] if typ == 4 else struct.unpack(e + 'H', data[b+8:b+10])[0]
    if 0x0201 in tags:
        o, l = tags[0x0201], tags[0x0202]
        open('%s-ifd%d.jpg' % (sys.argv[2], k), 'wb').write(data[o:o+l])
        print('ifd', k, 'jpeg', o, l)
    off = struct.unpack(e + 'I', data[off+2+12*n:off+6+12*n])[0]
    k += 1
