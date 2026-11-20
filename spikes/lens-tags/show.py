"""Prints a displacement field from register.py: the grid, then radial and colour shifts by ring."""
import sys
import numpy as np
d = np.load(sys.argv[1]); xs, ys, res, W, H = d['xs'], d['ys'], d['res'], int(d['W']), int(d['H'])
cx, cy = (W - 1) / 2, (H - 1) / 2
R = np.hypot(W / 2, H / 2)
print('W H', W, H, 'grid', len(xs), len(ys))
for name, c in (('G', 1), ('R-G', 0), ('B-G', 2)):
    print(name)
    for j in range(0, len(ys), max(1, len(ys) // 7)):
        row = []
        for i in range(0, len(xs), max(1, len(xs) // 7)):
            dx, dy, r = res[j, i, c]
            if c != 1:
                dx -= res[j, i, 1, 0]; dy -= res[j, i, 1, 1]
            row.append('(%+5.2f,%+5.2f|%.2f)' % (dx, dy, r))
        print('  y=%4d ' % ys[j] + ' '.join(row))
# radial component vs radius
g = res[..., 1, :]
X, Y = np.meshgrid(xs, ys)
rx, ry = X - cx, Y - cy
r = np.hypot(rx, ry)
radial = (g[..., 0] * rx + g[..., 1] * ry) / np.maximum(r, 1)
tang = (-g[..., 0] * ry + g[..., 1] * rx) / np.maximum(r, 1)
ok = g[..., 2] > float(sys.argv[2]) if len(sys.argv) > 2 else g[..., 2] > 0.3
print('green radial displacement by normalized radius (median, count), tangential median:')
for lo in np.arange(0, 1.0, 0.1):
    m = ok & (r / R >= lo) & (r / R < lo + 0.1)
    if m.sum():
        print('  %.1f-%.1f %+.3f px (n %d), tang %+.3f' % (lo, lo + 0.1, np.median(radial[m]), m.sum(), np.median(tang[m])))
for name, c in (('R-G', 0), ('B-G', 2)):
    d = res[..., c, :2] - g[..., :2]
    rad = (d[..., 0] * rx + d[..., 1] * ry) / np.maximum(r, 1)
    okc = ok & (res[..., c, 2] > 0.3)
    print(name, 'radial by radius:', ' '.join('%.1f:%+.3f' % (lo, np.median(rad[okc & (r / R >= lo) & (r / R < lo + 0.1)])) for lo in np.arange(0, 1.0, 0.1) if (okc & (r / R >= lo) & (r / R < lo + 0.1)).sum()))
