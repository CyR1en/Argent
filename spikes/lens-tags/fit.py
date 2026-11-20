"""Fit Sony's distortion model to a measured displacement field (register.py output).

Model: the corrected frame at output q shows the source (uncorrected) point
    p = c + (q - c) * (1 + u * f(n_knots_minus_1 * |q - c| / (k * rmax))) / s
with f the knots of 0x7037 interpolated (linear or Catmull-Rom), rmax the crop's half diagonal.
Measured: a feature at p in ours appears at q = p + d.
Usage: fit.py field.npz knots(comma) [mincorr]
"""
import sys
import numpy as np


def interp(knots, t, kind):
    n = len(knots)
    t = np.clip(t, 0, n - 1)
    i = np.clip(np.floor(t).astype(int), 0, n - 2)
    f = t - i
    k = np.asarray(knots, float)
    if kind == 'linear':
        return k[i] * (1 - f) + k[i + 1] * f
    # Catmull-Rom with end knots repeated linearly.
    ext = np.concatenate([[2 * k[0] - k[1]], k, [2 * k[-1] - k[-2]]])
    p0, p1, p2, p3 = ext[i], ext[i + 1], ext[i + 2], ext[i + 3]
    return 0.5 * ((2 * p1) + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f + (-p0 + 3 * p1 - 3 * p2 + p3) * f ** 3)


def model(params, q, W, H, knots, kind, fixed):
    u, s, k, cx, cy, tx, ty = params
    c = np.array([(W - 1) / 2 + cx, (H - 1) / 2 + cy])
    rmax = np.hypot(W / 2, H / 2)
    v = q - c
    r = np.hypot(v[:, 0], v[:, 1])
    g = 1 + u * 1e-4 * interp(knots, (len(knots) - 1) * r / (k * rmax), kind)
    return c + v * (g / s)[:, None] + np.array([tx, ty])


def fit(p, q, W, H, knots, kind, free):
    x = np.array([0.6103515625, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0])  # u in 1e-4: 2^-14 = 0.6104e-4
    names = ['u(1e-4)', 's', 'k', 'cx', 'cy', 'tx', 'ty']
    idx = [names.index(n) for n in free]
    for _ in range(50):
        res = (model(x, q, W, H, knots, kind, None) - p).ravel()
        J = np.zeros((res.size, len(idx)))
        for j, ii in enumerate(idx):
            dx = np.zeros_like(x)
            dx[ii] = 1e-6 if ii != 0 else 1e-6
            J[:, j] = ((model(x + dx, q, W, H, knots, kind, None) - p).ravel() - res) / dx[ii]
        step = np.linalg.lstsq(J, -res, rcond=None)[0]
        x[idx] += step
        if np.abs(step).max() < 1e-9:
            break
    res = model(x, q, W, H, knots, kind, None) - p
    return x, res


def main():
    d = np.load(sys.argv[1])
    knots = [float(v) for v in sys.argv[2].split(',')]
    mincorr = float(sys.argv[3]) if len(sys.argv) > 3 else 0.4
    xs, ys, res, W, H = d['xs'], d['ys'], d['res'], int(d['W']), int(d['H'])
    X, Y = np.meshgrid(xs, ys)
    g = res[..., 1, :]
    ok = (g[..., 2] > mincorr) & (np.abs(g[..., 0]) < 10) & (np.abs(g[..., 1]) < 10)
    p = np.stack([X[ok], Y[ok]], 1).astype(float)
    q = p + np.stack([g[..., 0][ok], g[..., 1][ok]], 1)
    print('points', ok.sum(), 'of', ok.size)
    rmax = np.hypot(W / 2, H / 2)
    for kind in ('linear', 'cubic'):
        for free in (['s'], ['u(1e-4)', 's'], ['u(1e-4)', 's', 'k'], ['u(1e-4)', 's', 'cx', 'cy'], ['s', 'k'],
                     ['u(1e-4)', 's', 'k', 'cx', 'cy', 'tx', 'ty']):
            x, r = fit(p, q, W, H, knots, kind, free)
            rms = np.sqrt((r ** 2).sum(1).mean())
            med = np.median(np.hypot(r[:, 0], r[:, 1]))
            print('%-6s free %-40s u %.4f (2^-14 = 0.6104) s %.6f (s-1)*2^14 %.2f k %.4f c (%+.2f, %+.2f) t (%+.2f, %+.2f): rms %.3f px, median %.3f'
                  % (kind, ','.join(free), x[0], x[1], (x[1] - 1) * 16384, x[2], x[3], x[4], x[5], x[6], rms, med))
    # Identity (no correction) for scale.
    r0 = q - p
    print('no-correction rms %.3f px' % np.sqrt((r0 ** 2).sum(1).mean()))
    # Corner-normalized prediction with nominal units.
    x = np.array([0.6103515625, 1 + 0.6103515625e-4 * knots[-1], 1, 0, 0, 0, 0])
    r = model(x, q, W, H, knots, 'linear', None) - p
    print('nominal (2^-14, knots to the corner, s = g(corner)): rms %.3f px, median %.3f' % (np.sqrt((r ** 2).sum(1).mean()), np.median(np.hypot(r[:, 0], r[:, 1]))))
    edge = max(knots[int(np.floor(15 * np.hypot(0, H / 2) / rmax)):])
    x[1] = 1 + 0.6103515625e-4 * edge
    r = model(x, q, W, H, knots, 'linear', None) - p
    print('nominal, s = max on the edge (%g): rms %.3f px' % (edge, np.sqrt((r ** 2).sum(1).mean())))


if __name__ == '__main__':
    main()
