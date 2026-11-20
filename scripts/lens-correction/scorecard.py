#!/usr/bin/env python3
"""Synthetic lens-stage gates. Defringe needs SciPy for its neutral charts."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import numpy as np


def table(knots):
    m = 960 // (len(knots) - 1)
    return np.array([knots[i // m] if i % m == 0 else
                     knots[i // m] + (knots[i // m + 1] - knots[i // m]) * (i % m) / m
                     for i in range(961)], dtype=np.float32).astype(np.float64)


def lookup(row, t):
    x = np.clip(t, 0, 1) * 960
    i = np.minimum(x.astype(np.int32), 959)
    return row[i] + (row[i + 1] - row[i]) * (x - i)


def framing(rows, shape):
    h, w = shape
    t0 = (min(w, h) - 1) / np.hypot(w, h)
    return max(max(lookup(row, t0), np.max(row[np.arange(961) / 960 > t0])) for row in rows[:3])


def coordinates(shape, first, last):
    h, w = shape
    return np.broadcast_arrays(np.arange(w, dtype=np.float64)[None, :],
                               np.arange(first, last, dtype=np.float64)[:, None])


def ideal_position(x, y, shape, row, scale):
    h, w = shape
    cx, cy, rmax = (w - 1) / 2, (h - 1) / 2, np.hypot(w, h) / 2
    r = np.hypot(x - cx, y - cy) / rmax
    lo, hi = np.zeros_like(r), np.full_like(r, 1.4)
    for _ in range(36):
        mid = (lo + hi) / 2
        inside = mid * lookup(row, mid) / scale < r
        lo = np.where(inside, mid, lo)
        hi = np.where(inside, hi, mid)
    factor = np.divide((lo + hi) / 2, r, out=np.ones_like(r), where=r > 0)
    return cx + (x - cx) * factor, cy + (y - cy) * factor


def scene(path, shape, evaluate):
    image = np.lib.format.open_memmap(path, mode='w+', dtype='<f4', shape=(*shape, 3))
    for first in range(0, shape[0], 64):
        last = min(first + 64, shape[0])
        x, y = coordinates(shape, first, last)
        image[first:last] = evaluate(x, y)
    image.flush()
    return image


def dots(x, y, shape, sigma):
    h, w = shape
    dx = ((x + 0.5) / w * 8 - np.rint((x + 0.5) / w * 8)) * w / 8
    dy = ((y + 0.5) / h * 6 - np.rint((y + 0.5) / h * 6)) * h / 6
    return (0.015625 + np.exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))[..., None]


def centres(image, sigma, channel=1):
    h, w = image.shape[:2]
    found = []
    radius = int(np.ceil(5 * sigma))
    for ky in range(1, 6):
        for kx in range(1, 8):
            cx, cy = kx * w / 8 - 0.5, ky * h / 6 - 0.5
            ix, iy = int(round(cx)), int(round(cy))
            patch = np.maximum(np.asarray(image[iy-radius:iy+radius+1, ix-radius:ix+radius+1, channel],
                                          dtype=np.float64) - 0.015625, 0)
            yy, xx = np.indices(patch.shape)
            found.append([ix - radius + np.sum(patch * xx) / patch.sum(),
                          iy - radius + np.sum(patch * yy) / patch.sum()])
    return np.array(found)


def area_resize(image, shape):
    result = np.asarray(image, dtype=np.float32)
    for axis, size in [(0, shape[0]), (1, shape[1])]:
        source = np.moveaxis(result, axis, 0)
        edges = np.linspace(0, source.shape[0], size + 1)
        whole = np.minimum(edges.astype(int), source.shape[0] - 1)
        integral = np.concatenate([np.zeros_like(source[:1]), np.cumsum(source, axis=0, dtype=np.float32)])
        at = integral[whole] + (edges - whole).reshape((-1,) + (1,) * (source.ndim - 1)) * source[whole]
        result = np.moveaxis((np.diff(at, axis=0) / (source.shape[0] / size)).astype(np.float32), 0, axis)
    return result


def mtf50(patch):
    y, x = np.indices(patch.shape)
    distance = x - (patch.shape[1] - 1) / 2 - (y - (patch.shape[0] - 1) / 2) / 8
    bins = np.floor((distance + 24) * 8).astype(int)
    valid = (bins >= 0) & (bins < 384)
    count = np.bincount(bins[valid], minlength=384)
    total = np.bincount(bins[valid], weights=patch[valid], minlength=384)
    esf = np.interp(np.arange(384), np.flatnonzero(count), total[count > 0] / count[count > 0])
    lsf = np.diff(esf) * np.hanning(383)
    spectrum = np.abs(np.fft.rfft(lsf, 8192))
    spectrum /= spectrum[0]
    index = np.flatnonzero(spectrum <= 0.5)[0]
    fraction = (spectrum[index-1] - 0.5) / (spectrum[index-1] - spectrum[index])
    return (index - 1 + fraction) * 8 / 8192


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--stage', action='store_true')
    mode.add_argument('--defringe', action='store_true')
    parser.add_argument('--chart', type=Path)
    parser.add_argument('--lightroom', type=Path)
    parser.add_argument('--spike', type=Path, required=True)
    parser.add_argument('--sample', type=Path, required=True)
    args = parser.parse_args()
    if args.defringe:
        if args.chart is None: parser.error("--defringe requires --chart DIR")
        from defringe_scorecard import run
        return run(args)
    root = Path(__file__).resolve().parents[2]
    stock = root / 'build/stocks/kodak-portra-400'
    if not stock.is_dir():
        stock = next((root / 'build/stocks').glob('*/stock.json')).parent
    passed = []
    with tempfile.TemporaryDirectory(prefix='argent-lc4-') as directory:
        work = Path(directory)
        serial = 0

        def run(input_path, knots, scale=0.25, identity=False):
            nonlocal serial
            serial += 1
            config, output = work / f'{serial}.json', work / f'{serial}-out.npy'
            config.write_text(json.dumps(dict(zip(['red', 'green', 'blue', 'gain'], knots))))
            command = [str(args.spike.resolve()), str(args.sample.resolve()), '--stock', str(stock),
                       '--scale', str(scale), '--no-lens', '--no-warmup', '--lens-stage', str(config),
                       '--scene-out', str(output), '--out', str(work / 'print')]
            if input_path is not None:
                command += ['--scene-in', str(input_path)]
            result = subprocess.run(command, text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError(result.stderr or result.stdout)
            lines = result.stdout.splitlines()
            skipped = 'lens stage  skipped' in lines
            if skipped and not identity:
                raise RuntimeError('FAIL: lens stage skipped for a non-identity check')
            if not any(line.startswith('lens stage  distortion ') for line in lines) and not (identity and skipped):
                raise RuntimeError('the spike did not run the lens stage')
            return np.load(output, mmap_mode='r')

        def report(number, name, ok, detail):
            passed.append(bool(ok))
            print(f'{number} {name}: {"PASS" if ok else "FAIL"} {detail}', flush=True)

        one = [[1, 1]] * 4
        shape = run(None, one, identity=True).shape[:2]
        h, w = shape
        source = work / 'scene.npy'
        rng = np.random.default_rng(412)
        identity = rng.uniform(-0.125, 4, (*shape, 3)).astype(np.float16).astype(np.float32)
        np.save(source, identity)
        report(1, 'identity', np.array_equal(run(source, one, identity=True), identity), 'half-float scene, bit for bit')
        del identity
        curve = (1 + np.linspace(0, 1, 16)**2 * 785 / 16384).tolist()
        knots = [curve, curve, curve, [1, 1]]
        rows = list(map(table, knots))
        s = framing(rows, shape)
        sigma = 4.0
        scene(source, shape, lambda x, y: dots(*ideal_position(x, y, shape, rows[1], s), shape, sigma))
        corrected = run(source, knots)
        target = np.array([[kx*w/8-0.5, ky*h/6-0.5] for ky in range(1, 6) for kx in range(1, 8)])
        error = np.max(np.linalg.norm(centres(corrected, sigma) - target, axis=1)) / 0.25
        report(2, 'dots', error < 0.01, f'largest {error:.6f} full-size px')

        hard_ulps, bright_ring, dark_ring, minimum = 0.0, 0.0, 0.0, np.inf
        fractions = set()
        if min(shape) < 1040:
            raise RuntimeError('sample is too small for the HDR edge sweep')
        # Each axis has four off-centre edges and 65 isolated coverage strips.
        # RGB holds the three contrasts. Coverage 0 and 1 are hard steps.
        for horizontal in [False, True]:
            length, cross = (h, w) if horizontal else (w, h)
            positions = (np.array([0.1, 0.3, 0.7, 0.9]) * length).astype(int)
            boundaries = (positions[:-1] + positions[1:]) / 2
            start = (cross - 1040) // 2

            def steps(x, y):
                along, across = (y, x) if horizontal else (x, y)
                edge = positions[np.searchsorted(boundaries, along)]
                coverage = np.clip((across.astype(int) - start) // 16, 0, 64) / 64
                return 1 + np.array([15, 255, 4095]) * np.clip(along-edge+coverage, 0, 1)[..., None]

            scene(source, shape, steps)
            edges = run(source, knots)
            minimum = min(minimum, float(np.min(edges)))
            for phase in range(65):
                for position in positions:
                    px, py = (start+phase*16+8, position) if horizontal else (position, start+phase*16+8)
                    qx, qy = ideal_position(np.array(px), np.array(py), shape, rows[1], s)
                    x, y = int(round(float(qx))), int(round(float(qy)))
                    xx, yy = ((np.full(17, x), np.arange(y-8, y+9)) if horizontal else
                              (np.arange(x-8, x+9), np.full(17, y)))
                    radius = np.hypot(xx-(w-1)/2, yy-(h-1)/2) / (np.hypot(w, h)/2)
                    centre, along = ((h-1)/2, yy) if horizontal else ((w-1)/2, xx)
                    reads = centre + (along-centre)*lookup(rows[1], radius)/s
                    beside_edge = reads[abs(reads-position) < 3]
                    fractions.update(np.floor((beside_edge % 1)*16).astype(int).tolist())
                    for channel, ratio in enumerate([16, 256, 4096]):
                        values = np.asarray(edges[yy, xx, channel], dtype=np.float64)
                        over, under = max(values.max()-ratio, 0), max(1-values.min(), 0)
                        if phase in [0, 64]:
                            up = float(np.nextafter(np.float16(ratio), np.float16(np.inf)))-ratio
                            down = 1-float(np.nextafter(np.float16(1), np.float16(0)))
                            hard_ulps = max(hard_ulps, over/up, under/down)
                        else:
                            bright_ring, dark_ring = max(bright_ring, over/ratio), max(dark_ring, under)
        report(3, 'hdr edges', hard_ulps <= 1 and max(bright_ring, dark_ring) < 0.01
               and minimum >= 0 and len(fractions) == 16,
               f'hard {hard_ulps:.3f} half steps; partial bright {100*bright_ring:.6f}%, dark {100*dark_ring:.6f}%; '
               f'minimum {minimum:.6g}; {len(fractions)}/16 fraction bins, 2 axes x 4 positions x 65 coverages x 3 ratios')

        regions = [(int(w*u), int(h*v)) for v in [0.2, 0.5, 0.8] for u in [0.2, 0.5, 0.8]]

        def edge_field(x, y):
            ix, iy = ideal_position(x, y, shape, rows[1], s)
            result = np.ones_like(x)
            for cx, cy in regions:
                near = (abs(ix-cx) < 80) & (abs(iy-cy) < 80)
                result = np.where(near, 1.5 + 0.5*np.tanh((ix-cx-(iy-cy)/8)/0.8), result)
            return result[..., None]

        scene(source, shape, edge_field)
        edge = run(source, knots)
        yy, xx = np.indices((96, 96))
        baseline = mtf50(1.5 + 0.5*np.tanh((xx-48-(yy-48)/8)/0.8))
        # Inverse-warping the analytic edge above already removes each region's local scale.
        retention = [mtf50(edge[cy-48:cy+48, cx-48:cx+48, 1]) / baseline for cx, cy in regions]
        med, worst = np.median(retention), min(retention)
        report(4, 'mtf', med >= 0.95 and worst >= 0.90, f'MTF50 median {med:.6f}, worst {worst:.6f}')

        full_shape = run(None, one, 1, identity=True).shape[:2]
        # Fixed scene detail survives a 960-pixel preview and exposes a skipped warp.
        scene(source, full_shape, lambda x, y: (1 + 0.3*np.sin(2*np.pi*(37*x/full_shape[1]+11*y/full_shape[0]))
                                               + 0.2*np.cos(2*np.pi*(17*x/full_shape[1]-43*y/full_shape[0]))
                                               + 0.1*np.sin(2*np.pi*(73*x/full_shape[1]+61*y/full_shape[0])))[..., None])
        full = run(source, knots, 1)
        preview_scale = 960 / max(full_shape)
        preview_shape = run(None, one, preview_scale, identity=True).shape[:2]
        preview_input = area_resize(np.load(source, mmap_mode='r'), preview_shape)
        np.save(work / 'preview.npy', preview_input)
        preview = run(work / 'preview.npy', knots, preview_scale)
        resized = area_resize(full, preview_shape)
        gradient = np.sqrt(sum(np.mean(g*g) for g in np.gradient(resized[..., 1])))
        parity = np.sqrt(np.mean((preview-resized)**2)) / gradient
        effect = np.sqrt(np.mean((preview-preview_input)**2))
        report(5, 'preview parity', parity < 0.1 and gradient > 0.05 and effect > 0.01,
               f'RMS difference / RMS gradient {parity:.6f} px, warp RMS {effect:.6f}, {max(preview_shape)} px long side')
        del full, resized, preview, preview_input

        corner = np.hypot(*full_shape) / 2
        colour_knots = [[1+1/corner]*2, [1, 1], [1-1/corner]*2, [1, 1]]
        colour_rows = list(map(table, colour_knots))
        colour_s = framing(colour_rows, full_shape)

        def coloured(x, y):
            return np.concatenate([dots(*ideal_position(x, y, shape, row, colour_s), shape, sigma)
                                   for row in colour_rows[:3]], axis=2)

        scene(source, shape, coloured)
        colour = run(source, colour_knots)
        residual = max(np.max(np.linalg.norm(centres(colour, sigma, ch)-centres(colour, sigma), axis=1))
                       for ch in [0, 2]) / 0.25
        report(6, 'channels', residual < 0.05, f'largest {residual:.6f} full-size px')
        gain = [1, 1.15, 1.4, 1.7, 2]
        gain_row = table(gain)
        scene(source, shape, lambda x, y: (0.125 / lookup(gain_row, np.hypot(x-(w-1)/2, y-(h-1)/2)
                                                        / (np.hypot(w, h)/2)))[..., None])
        flat = run(source, [[1, 1]]*3 + [gain])
        x, y = coordinates(shape, 0, h)
        rings = np.minimum((np.hypot(x-(w-1)/2, y-(h-1)/2)/(np.hypot(w, h)/2)*32).astype(int), 31)
        errors = [abs(np.log2(np.mean(flat[..., 1][rings == i], dtype=np.float64)/0.125)) for i in range(32)]
        report(7, 'gain', max(errors) < 0.005, f'worst ring {max(errors):.6f} stop')
    return 0 if all(passed) else 1


if __name__ == '__main__':
    raise SystemExit(main())
